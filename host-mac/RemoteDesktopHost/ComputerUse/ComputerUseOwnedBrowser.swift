import AppKit
import SwiftUI
import WebKit

struct ComputerUseBrowserTaskControls: Equatable {
    enum Phase: Equatable { case working, paused, awaitingApproval }
    enum Action { case takeControl, resume, stop }
    let taskID: String
    let scopeID: UUID
    let presentationID: UUID
    let phase: Phase
    let canResume: Bool
    /// Stable through Pause/Resume; changes with peer, session, authorization,
    /// transport or task ownership. Button authority still uses scopeID.
    let ownerID: UUID

    init(taskID: String, scopeID: UUID, presentationID: UUID, phase: Phase,
         canResume: Bool, ownerID: UUID? = nil) {
        self.taskID = taskID
        self.scopeID = scopeID
        self.presentationID = presentationID
        self.phase = phase
        self.canResume = canResume
        self.ownerID = ownerID ?? scopeID
    }
}

/// A display projection, never a navigation target or document identity. Page
/// paths, queries and fragments may carry opaque login values under any name.
/// Keep only website identity; never fall back to the original URL string.
enum ComputerUseBrowserSite {
    static func displayName(for url: URL?) -> String {
        guard let url, let validated = ComputerUseOwnedBrowser.validatedURL(url),
              var components = URLComponents(url: validated, resolvingAgainstBaseURL: false) else {
            return "Website unavailable"
        }
        components.scheme = components.scheme?.lowercased()
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "Website unavailable"
    }
}

struct ComputerUseBrowserDocument: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Source: Equatable, Sendable {
        case automationNavigation
        case activePageObservation
        case userControlObservation
        case taskAdmissionObservation
    }
    let contextID: String
    let taskID: String
    let generation: UInt64
    let operationID: String
    let requestedURL: URL
    let committedURL: URL
    let source: Source

    // Standard interpolation and debug logging must not expand retained URLs
    // (or caller-supplied task/operation IDs) into callback secrets.
    var description: String {
        "ComputerUseBrowserDocument(site: \(ComputerUseBrowserSite.displayName(for: committedURL)), source: \(source))"
    }
    var debugDescription: String { description }

    init(contextID: String, taskID: String, generation: UInt64, operationID: String,
         requestedURL: URL, committedURL: URL, source: Source = .automationNavigation) {
        self.contextID = contextID
        self.taskID = taskID
        self.generation = generation
        self.operationID = operationID
        self.requestedURL = requestedURL
        self.committedURL = committedURL
        self.source = source
    }
}

/// Keeps the navigation/document authority beside the DOM observation. A
/// model sees a bounded projection only after a capability chooses one; this
/// object itself is never a completion or an input authorization.
struct ComputerUseBrowserPageEvidence: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let document: ComputerUseBrowserDocument
    let documentID: String
    let page: ComputerUseBrowserPageSnapshot

    fileprivate init(document: ComputerUseBrowserDocument, documentID: String, page: ComputerUseBrowserPageSnapshot) {
        self.document = document
        self.documentID = documentID
        self.page = page
    }

    var description: String { "ComputerUseBrowserPageEvidence(\(document), \(page))" }
    var debugDescription: String { description }
}

/// A host-observed document destination, not authority to click arbitrary
/// page controls. A task compiler must separately authorize this operation.
/// Exact URLs stay private to the adapter and never enter planner context.
struct ComputerUseBrowserNavigationTarget: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate enum Source: Equatable, Sendable {
        case link(String)
        case history(String), revisit(String)
        case formQuery(controlID: String, queryID: String, requirementsDigest: String?)
        var identity: [String] {
            switch self {
            case .link(let id): return ["link", id]
            case .history(let id): return ["history", id]
            case .revisit(let id): return ["revisit", id]
            case .formQuery(let controlID, let queryID, let requirementsDigest):
                return ["form-query", controlID, queryID] + (requirementsDigest.map { ["verified-edits", $0] } ?? [])
            }
        }
    }
    fileprivate let evidence: ComputerUseBrowserPageEvidence
    fileprivate let source: Source
    fileprivate let destination: URL
    fileprivate let sourcePolicyDigest: String?
    let payloadDigest: String
    var taskID: String { evidence.document.taskID }
    var contextID: String { evidence.document.contextID }
    var destinationIdentity: String { ComputerUseTaskContract.digest([destination.absoluteString]) }
    func isBound(to page: ComputerUseBrowserPageEvidence) -> Bool { evidence == page }

    fileprivate init(evidence: ComputerUseBrowserPageEvidence, source: Source, destination: URL, sourcePolicyDigest: String? = nil) {
        self.evidence = evidence; self.source = source; self.destination = destination
        self.sourcePolicyDigest = sourcePolicyDigest
        payloadDigest = ComputerUseTaskContract.digest(["browser-observed-destination-v1", evidence.document.contextID,
            evidence.document.taskID, String(evidence.document.generation), evidence.documentID, evidence.page.id,
            destination.absoluteString] + source.identity + (sourcePolicyDigest.map { ["source-policy", $0] } ?? []))
    }

    var description: String { "BrowserObservedDestination(site: \(ComputerUseBrowserSite.displayName(for: destination)))" }
    var debugDescription: String { description }
}

/// Model-visible visit indices map to native history objects or a confirmed
/// GET destination. The target itself never enters the model's JSON.
struct ComputerUseBrowserHistoryOption: Equatable, Sendable {
    enum Mode: String, Sendable { case back, forward, revisit }
    let visit: Int
    let operationID: String
    let mode: Mode
    let target: ComputerUseBrowserNavigationTarget
    fileprivate init(visit: Int, operationID: String, mode: Mode, target: ComputerUseBrowserNavigationTarget) {
        self.visit = visit; self.operationID = operationID; self.mode = mode; self.target = target
    }
}

/// A handoff binds the live browser session and ownership epoch, not the old
/// document: signing in may legitimately navigate to a newly observed page.
struct ComputerUseBrowserHandbackRequirement: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    fileprivate let contextID: String?
    fileprivate let sessionID: UUID?
    fileprivate let ownershipEpoch: UUID?
    fileprivate let requiresPresentation: Bool

    fileprivate init(taskID: String, contextID: String?, sessionID: UUID?, ownershipEpoch: UUID?, requiresPresentation: Bool) {
        self.taskID = taskID; self.contextID = contextID; self.sessionID = sessionID
        self.ownershipEpoch = ownershipEpoch; self.requiresPresentation = requiresPresentation
    }

    static func unavailable(taskID: String) -> Self {
        .init(taskID: taskID, contextID: nil, sessionID: nil, ownershipEpoch: nil, requiresPresentation: true)
    }

    var description: String { "BrowserHandbackRequirement" }
    var debugDescription: String { description }

    var sessionBindingDigest: String {
        ComputerUseTaskContract.digest(["browser-session-v1", taskID, contextID ?? "",
            sessionID?.uuidString ?? "", ownershipEpoch?.uuidString ?? ""])
    }
}

struct ComputerUseBrowserNavigationReceipt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let payloadDigest: String
    let document: ComputerUseBrowserDocument
    var description: String { "BrowserObservedNavigation(\(document))" }
    var debugDescription: String { description }
}

/// Native dispatch history, not a complete route or a source-compliance proof.
/// Only the owning browser can construct or update it. Origins omit paths,
/// queries, fragments and credentials; this value never enters planner JSON.
struct ComputerUseBrowserNavigationDispatchHistory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Outcome: String, Sendable { case pending, documentCommitted, failed, sourceBlocked, ownershipLost, timedOut }
    /// The native branch that admitted the receipt. A response remains
    /// associated with the pending slot, not an exact WKNavigation.
    enum CommitBasis: String, Sendable { case responseAndFinish, historyItemAndFinish, instantBackHistoryItem }
    enum Phase: String, Sendable {
        case navigationAction, response, serverRedirect, historyRequest, popupRequest
        case provisionalStart, documentCommitStarted, documentFinished, navigationFailure, webContentTerminated
        case locationChanged, unorderedLocationChange
        case observedNavigationEnded
    }
    /// Why the native owner stopped tracking this observed load. This is
    /// not proof of network cancellation, response association or adoption.
    enum ObservedNavigationEnd: String, Sendable {
        case finished, finishRejected, responseRejected, sourceBlocked, callbackFailed
        case superseded, stopped, closed, browserReleased, processTerminated
    }
    enum Decision: String, Sendable { case observed, allowed, cancelled }
    enum Binding: String, Sendable {
        case none, pendingSlot, observedSlot, exactPendingNavigation, exactObservedNavigation, exactHistoryItem
    }
    /// State of the control gate at this event, not proof of who initiated it.
    enum Control: String, Sendable { case unknown, automationAllowed, userControl }
    enum Surface: String, Sendable { case mainDocument, signInWindow }
    enum PolicyCheck: String, Sendable { case notChecked, unconfigured, permitted, blocked }
    enum ControlPhase: String, Sendable {
        case workflowPaused, workflowResumeStarted, workflowContextAdmitted, workflowResumed, workflowResumeFailed
        case nativeReacquisitionStarted, nativeReacquisitionFinished, nativeReacquisitionFailed
        case signInWindowOpened, signInWindowClosed
    }
    /// Native claim lifetime, separate from workflow Pause/Resume and from
    /// the browser session that may be allocated only after the claim starts.
    struct ClaimEvent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Phase: String, Sendable { case claimed, sessionCreated, retired }
        enum Retirement: String, Sendable { case stopped, closed, replaced }
        let order: Int
        let phase: Phase
        let parentSessionID: UUID?
        let ownershipEpoch: UUID
        let generation: UInt64
        let retirement: Retirement?

        fileprivate init(order: Int, phase: Phase, parentSessionID: UUID?, ownershipEpoch: UUID,
                         generation: UInt64, retirement: Retirement?) {
            self.order = order; self.phase = phase; self.parentSessionID = parentSessionID
            self.ownershipEpoch = ownershipEpoch; self.generation = generation
            self.retirement = phase == .retired ? retirement : nil
        }
        var description: String { "BrowserClaimEvent(phase: \(phase.rawValue))" }
        var debugDescription: String { description }
    }
    /// Native acceptance of an observed page, not an automation receipt or
    /// evidence that its load was initiated by a person rather than a script.
    struct PageObservation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Basis: String, Sendable { case completedNavigation, sameDocumentCandidate }
        let id: UUID
        let taskID: String
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let origin: ComputerUseBrowserSourceOrigin?
        let basis: Basis
        let navigationCorrelationID: UUID?
        let source: ComputerUseBrowserDocument.Source
        let requiresExplicitHandback: Bool

        fileprivate init(taskID: String, parentSessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                         url: URL, basis: Basis, navigationCorrelationID: UUID?,
                         source: ComputerUseBrowserDocument.Source, requiresExplicitHandback: Bool) {
            id = UUID(); self.taskID = taskID; self.parentSessionID = parentSessionID; self.ownershipEpoch = ownershipEpoch
            self.generation = generation; origin = try? .init(url); self.basis = basis
            self.navigationCorrelationID = navigationCorrelationID; self.source = source
            self.requiresExplicitHandback = requiresExplicitHandback
        }
        var description: String { "BrowserPageObservation(basis: \(basis.rawValue))" }
        var debugDescription: String { description }
    }
    struct PageObservationEvent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Phase: String, Sendable { case accepted, adopted, retired }
        enum Retirement: String, Sendable {
            case navigationStarted, locationChanged, identityMismatch, claimChanged, taskAdmission
            case stopped, closed, browserReleased, processTerminated, responseRejected, sourceBlocked, navigationFailed
        }
        let order: Int
        let phase: Phase
        let observation: PageObservation
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let adoptedSource: ComputerUseBrowserDocument.Source?
        let nativeReacquisitionID: UUID?
        let retirement: Retirement?

        fileprivate init(order: Int, phase: Phase, observation: PageObservation, parentSessionID: UUID,
                         ownershipEpoch: UUID, generation: UInt64, adoptedSource: ComputerUseBrowserDocument.Source?,
                         nativeReacquisitionID: UUID?, retirement: Retirement?) {
            self.order = order; self.phase = phase; self.observation = observation; self.parentSessionID = parentSessionID
            self.ownershipEpoch = ownershipEpoch; self.generation = generation
            self.adoptedSource = adoptedSource; self.nativeReacquisitionID = nativeReacquisitionID
            self.retirement = phase == .retired ? retirement : nil
        }
        var description: String { "BrowserPageObservationEvent(phase: \(phase.rawValue))" }
        var debugDescription: String { description }
    }
    /// An accepted native configuration change, not a navigation or evidence
    /// that earlier activity complied with the newly installed policy.
    struct PolicyInstallation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let order: Int
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let previousPolicy: ComputerUseBrowserSourcePolicy?
        let policy: ComputerUseBrowserSourcePolicy

        fileprivate init(order: Int, parentSessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                         previousPolicy: ComputerUseBrowserSourcePolicy?, policy: ComputerUseBrowserSourcePolicy) {
            self.order = order; self.parentSessionID = parentSessionID; self.ownershipEpoch = ownershipEpoch
            self.generation = generation; self.previousPolicy = previousPolicy; self.policy = policy
        }
        var description: String { "BrowserSourcePolicyInstallation" }
        var debugDescription: String { description }
    }
    struct ControlEvent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let order: Int
        let phase: ControlPhase
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let origin: ComputerUseBrowserSourceOrigin?
        let handback: ComputerUseBrowserHandbackRequirement?
        var handbackBinding: String? { handback?.sessionBindingDigest }
        let workflowOperationID: UUID?
        let nativeOperationID: UUID?
        let signInWindowID: UUID?

        fileprivate init(order: Int, phase: ControlPhase, parentSessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                         url: URL?, handback: ComputerUseBrowserHandbackRequirement?, workflowOperationID: UUID?, nativeOperationID: UUID?, signInWindowID: UUID?) {
            self.order = order; self.phase = phase; self.parentSessionID = parentSessionID
            self.ownershipEpoch = ownershipEpoch; self.generation = generation; origin = url.flatMap { try? .init($0) }
            self.handback = handback; self.workflowOperationID = workflowOperationID
            self.nativeOperationID = nativeOperationID; self.signInWindowID = signInWindowID
        }
        var description: String { "BrowserControlEvent(phase: \(phase.rawValue))" }
        var debugDescription: String { description }
    }
    struct Observation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let order: Int
        let phase: Phase
        let instantBack: Bool?
        let observedEnd: ObservedNavigationEnd?
        let decision: Decision
        let binding: Binding
        let control: Control
        let surface: Surface
        let policyCheck: PolicyCheck
        let configuredPolicy: ComputerUseBrowserSourcePolicy?
        let origin: ComputerUseBrowserSourceOrigin?
        let attemptID: UUID?
        let navigationCorrelationID: UUID?
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let signInWindowID: UUID?

        fileprivate init(order: Int, phase: Phase, decision: Decision, binding: Binding, control: Control, surface: Surface,
                         policyCheck: PolicyCheck, configuredPolicy: ComputerUseBrowserSourcePolicy?, url: URL?,
                         attemptID: UUID?, navigationCorrelationID: UUID?, parentSessionID: UUID,
                         ownershipEpoch: UUID, generation: UInt64, signInWindowID: UUID?, instantBack: Bool?, observedEnd: ObservedNavigationEnd?) {
            self.order = order; self.signInWindowID = signInWindowID
            self.instantBack = phase == .historyRequest ? instantBack : nil
            self.observedEnd = phase == .observedNavigationEnded ? observedEnd : nil
            self.phase = phase; self.decision = decision; self.binding = binding; self.control = control
            self.surface = surface; self.policyCheck = policyCheck; self.configuredPolicy = configuredPolicy
            origin = url.flatMap { try? .init($0) }; self.attemptID = attemptID
            self.navigationCorrelationID = navigationCorrelationID; self.parentSessionID = parentSessionID
            self.ownershipEpoch = ownershipEpoch; self.generation = generation
        }
        var description: String { "BrowserNavigationObservation(phase: \(phase.rawValue), binding: \(binding.rawValue))" }
        var debugDescription: String { description }
    }
    struct Attempt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let order: Int
        let id: UUID
        let operationID: String
        let sessionID: UUID
        let ownershipEpoch: UUID
        let generation: UInt64
        let policy: ComputerUseBrowserSourcePolicy?
        let requestedOrigin: ComputerUseBrowserSourceOrigin?
        let historySourceOperationID: String?
        fileprivate(set) var committedOrigin: ComputerUseBrowserSourceOrigin?
        fileprivate(set) var commitBasis: CommitBasis?
        fileprivate(set) var successfulResponseOrigin: ComputerUseBrowserSourceOrigin?
        fileprivate(set) var outcome: Outcome
        fileprivate(set) var terminalOrder: Int?

        fileprivate init(order: Int, operationID: String, sessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                         policy: ComputerUseBrowserSourcePolicy?, requestedURL: URL, historySourceOperationID: String?) {
            self.order = order; terminalOrder = nil
            id = UUID(); self.operationID = operationID; self.sessionID = sessionID; self.ownershipEpoch = ownershipEpoch
            self.generation = generation; self.policy = policy; self.historySourceOperationID = historySourceOperationID
            requestedOrigin = try? .init(requestedURL); committedOrigin = nil; outcome = .pending
            commitBasis = nil; successfulResponseOrigin = nil
        }
        var description: String { "BrowserNavigationDispatch(outcome: \(outcome.rawValue))" }
        var debugDescription: String { description }
    }

    let taskID: String
    let contextID: String
    /// A different claim's history was discarded before this ledger began.
    /// Its absence must not be interpreted as a pristine browser/task history.
    let beganAfterAnotherClaim: Bool
    /// Stop/reclaim boundary only; absence does not prove that no manual
    /// pause, handback, scripted navigation or other transition occurred.
    fileprivate(set) var hasClaimBoundary = false
    fileprivate(set) var overflowed = false
    fileprivate(set) var attempts: [Attempt] = []
    fileprivate(set) var observations: [Observation] = []
    fileprivate(set) var observationsOverflowed = false
    fileprivate(set) var controlEvents: [ControlEvent] = []
    fileprivate(set) var controlEventsOverflowed = false
    fileprivate(set) var policyInstallations: [PolicyInstallation] = []
    fileprivate(set) var policyInstallationsOverflowed = false
    fileprivate(set) var pageObservationEvents: [PageObservationEvent] = []
    fileprivate(set) var pageObservationEventsOverflowed = false
    fileprivate(set) var claimEvents: [ClaimEvent] = []
    fileprivate(set) var claimEventsOverflowed = false
    private let ledgerID = UUID()
    private var revision = UUID()
    /// Ordinals cover retained records only. With 64 attempts, 64 terminal
    /// outcomes, 512 observations, 128 control events, 64 installations and
    /// 128 page-observation events and 128 claim events
    /// this cannot overflow.
    /// Omitted activity is represented by the separate overflow markers.
    private var nextOrder = 0

    fileprivate init(taskID: String, contextID: String, beganAfterAnotherClaim: Bool) {
        self.taskID = taskID; self.contextID = contextID; self.beganAfterAnotherClaim = beganAfterAnotherClaim
    }
    var identity: String {
        ComputerUseTaskContract.digest(["browser-navigation-dispatch-history-v8", taskID, contextID,
            ledgerID.uuidString, revision.uuidString])
    }
    fileprivate mutating func recordClaim(phase: ClaimEvent.Phase, parentSessionID: UUID?, ownershipEpoch: UUID,
                                          generation: UInt64, retirement: ClaimEvent.Retirement? = nil) {
        if phase == .retired || (phase == .claimed && !claimEvents.isEmpty) { hasClaimBoundary = true }
        advanceRevision()
        guard claimEvents.count < 128 else { claimEventsOverflowed = true; return }
        let order = takeOrder()
        claimEvents.append(.init(order: order, phase: phase, parentSessionID: parentSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, retirement: retirement))
    }
    fileprivate mutating func recordPolicyInstallation(parentSessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                                                       previousPolicy: ComputerUseBrowserSourcePolicy?, policy: ComputerUseBrowserSourcePolicy) {
        // Even after saturation, an actual configuration change invalidates
        // snapshots. Idempotent installation never calls this method.
        advanceRevision()
        guard policyInstallations.count < 64 else { policyInstallationsOverflowed = true; return }
        let order = takeOrder()
        policyInstallations.append(.init(order: order, parentSessionID: parentSessionID, ownershipEpoch: ownershipEpoch,
            generation: generation, previousPolicy: previousPolicy, policy: policy))
    }
    fileprivate mutating func begin(operationID: String, sessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                                    policy: ComputerUseBrowserSourcePolicy?, requestedURL: URL,
                                    historySourceOperationID: String?) -> UUID? {
        advanceRevision()
        // The same task may be claimed again after Stop. Preserve its earlier
        // attempts without allowing repeated claims to grow this log forever.
        guard attempts.count < 64 else { overflowed = true; return nil }
        let order = takeOrder()
        let attempt = Attempt(order: order, operationID: operationID, sessionID: sessionID, ownershipEpoch: ownershipEpoch,
            generation: generation, policy: policy, requestedURL: requestedURL, historySourceOperationID: historySourceOperationID)
        attempts.append(attempt)
        return attempt.id
    }
    fileprivate mutating func finish(_ id: UUID?, outcome: Outcome, committedURL: URL? = nil,
                                    commitBasis: CommitBasis? = nil, successfulResponseURL: URL? = nil) {
        guard outcome != .pending, let id, let index = attempts.firstIndex(where: { $0.id == id }),
              attempts[index].outcome == .pending else { return }
        advanceRevision()
        let terminalOrder = takeOrder()
        attempts[index].outcome = outcome
        attempts[index].terminalOrder = terminalOrder
        attempts[index].committedOrigin = committedURL.flatMap { try? .init($0) }
        attempts[index].commitBasis = outcome == .documentCommitted ? commitBasis : nil
        attempts[index].successfulResponseOrigin = outcome == .documentCommitted ? successfulResponseURL.flatMap { try? .init($0) } : nil
    }
    fileprivate mutating func observe(phase: Phase, decision: Decision, binding: Binding, control: Control, surface: Surface,
                                      policyCheck: PolicyCheck, configuredPolicy: ComputerUseBrowserSourcePolicy?, url: URL?,
                                      attemptID: UUID?, navigationCorrelationID: UUID?, parentSessionID: UUID,
                                      ownershipEpoch: UUID, generation: UInt64, signInWindowID: UUID?, instantBack: Bool?, observedEnd: ObservedNavigationEnd? = nil) {
        // Retain bounded observations and a gap. Omitted callbacks still
        // invalidate snapshots, without allocating a record or parsing URLs.
        advanceRevision()
        guard observations.count < 512 else {
            observationsOverflowed = true
            return
        }
        let order = takeOrder()
        observations.append(.init(order: order, phase: phase, decision: decision, binding: binding, control: control, surface: surface,
            policyCheck: policyCheck, configuredPolicy: configuredPolicy, url: url, attemptID: attemptID,
            navigationCorrelationID: navigationCorrelationID, parentSessionID: parentSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, signInWindowID: signInWindowID, instantBack: instantBack, observedEnd: observedEnd))
    }
    fileprivate mutating func recordControl(phase: ControlPhase, parentSessionID: UUID, ownershipEpoch: UUID,
                                            generation: UInt64, url: URL?, handback: ComputerUseBrowserHandbackRequirement?,
                                            workflowOperationID: UUID?, nativeOperationID: UUID?, signInWindowID: UUID?) {
        advanceRevision()
        guard controlEvents.count < 128 else {
            controlEventsOverflowed = true
            return
        }
        let order = takeOrder()
        controlEvents.append(.init(order: order, phase: phase, parentSessionID: parentSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: url, handback: handback,
            workflowOperationID: workflowOperationID, nativeOperationID: nativeOperationID, signInWindowID: signInWindowID))
    }
    fileprivate mutating func recordPageObservation(phase: PageObservationEvent.Phase, observation: PageObservation,
                                                    parentSessionID: UUID, ownershipEpoch: UUID, generation: UInt64,
                                                    adoptedSource: ComputerUseBrowserDocument.Source?, nativeReacquisitionID: UUID?, retirement: PageObservationEvent.Retirement?) {
        advanceRevision()
        guard pageObservationEvents.count < 128 else { pageObservationEventsOverflowed = true; return }
        let order = takeOrder()
        pageObservationEvents.append(.init(order: order, phase: phase, observation: observation,
            parentSessionID: parentSessionID, ownershipEpoch: ownershipEpoch, generation: generation,
            adoptedSource: adoptedSource, nativeReacquisitionID: nativeReacquisitionID, retirement: retirement))
    }
    private mutating func takeOrder() -> Int {
        defer { nextOrder += 1 }
        return nextOrder
    }
    private mutating func advanceRevision() {
        revision = UUID()
    }
    var description: String { "BrowserNavigationDispatchHistory(attempts: \(attempts.count), overflowed: \(overflowed))" }
    var debugDescription: String { description }
}

enum ComputerUseBrowserError: Error, LocalizedError, Equatable {
    case observedNavigationRetired
    case invalidURL, busy, ownershipLost, pageChanged, navigationFailed, deadlineExceeded, closed, unsupportedDocument, pageEvidenceUnavailable, documentUnresponsive, windowNotActive, authenticationRequired, signInWindowOpen, handbackContextLost, viewportScrollUnavailable, viewportScrollUncertain, linkNavigationUnavailable, observedNavigationUnavailable, observedNavigationUncertain, formQueryUnavailable, formQueryInvalid, sourceNotAllowed
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The browser needs an HTTP or HTTPS URL without embedded credentials."
        case .busy: return "The AI browser already has a navigation in progress."
        case .ownershipLost: return "Control of the AI browser changed before the operation finished."
        case .pageChanged: return "The browser page changed. Its previous document reference is no longer valid."
        case .navigationFailed: return "The requested page could not be opened successfully."
        case .deadlineExceeded: return "The browser did not finish opening the page before the deadline."
        case .closed: return "The AI browser window was closed."
        case .unsupportedDocument: return "This page does not expose a complete supported text form in the AI browser."
        case .pageEvidenceUnavailable: return "I couldn't read the current browser page well enough to verify this task."
        case .documentUnresponsive: return "The AI browser page did not respond before the deadline. Check it before continuing."
        case .windowNotActive: return "The AI browser is open, but another Mac window still has focus. Select the AI browser, then continue."
        case .authenticationRequired: return "Sign in or complete verification yourself in the AI browser, then choose Let AI continue. AI will check the page again before continuing your request."
        case .signInWindowOpen: return "Finish or close the sign-in window, then choose Let AI continue in the AI browser."
        case .viewportScrollUnavailable: return "This page does not expose a supported document viewport for scrolling."
        case .viewportScrollUncertain: return "I couldn't verify how the AI browser page moved. Check the page before continuing."
        case .linkNavigationUnavailable: return "This page link cannot be opened as a document in the current AI browser."
        case .observedNavigationUnavailable: return "This browser destination cannot be opened with its current reference."
        case .observedNavigationUncertain: return "I couldn't verify the navigation. Check the AI browser before continuing."
        case .observedNavigationRetired: return "This earlier navigation was cancelled before it started. Choose a new step from the current page."
        case .handbackContextLost: return "The AI browser session for this task was closed or replaced. Start a new browser task to continue."
        case .formQueryUnavailable: return "This form cannot be opened as a verified query in the AI browser."
        case .formQueryInvalid: return "The form contains a value that does not meet its requirements. Check the form before continuing."
        case .sourceNotAllowed: return "This page is outside the sources allowed for your request. Return to an allowed source, then choose Resume. The original request remains pending."
        }
    }
}

/// Owns one visible WebKit context. It never addresses Safari/Chrome windows,
/// imports their cookies, or accepts model-supplied JavaScript. Navigation
/// receipts come from the exact WKNavigation owned by the current task.
@MainActor
final class ComputerUseOwnedBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private typealias NavigationHistory = ComputerUseBrowserNavigationDispatchHistory
    let contextID = UUID().uuidString
    @Published private(set) var displayedSite = ComputerUseBrowserSite.displayName(for: nil)
    @Published private(set) var detail = "Ready"
    @Published private(set) var taskControls: ComputerUseBrowserTaskControls?
    @Published private(set) var signInSite: String?
    @Published private(set) var signInDetail = "You control this window. AI is paused."
    private var taskControlHandler: ((ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void)?
    private(set) var taskID: String?
    private var generation: UInt64 = 0
    private var ownershipEpoch = UUID()
    private var browserSessionID = UUID()
    /// Monotonic for one WKWebView lifetime. A failed/cancelled load or a URL
    /// returning to nil cannot turn a used session into an untouched one.
    private var sessionHasNavigationActivity = false
    private var locationRevision: UInt64 = 0
    private var document: ComputerUseBrowserDocument?
    private var sourcePolicy: ComputerUseBrowserSourcePolicy?
    private var receipts: [String: ComputerUseBrowserDocument] = [:]
    private struct HistoryReceipt {
        let item: WKBackForwardListItem
        let url: URL
        let document: ComputerUseBrowserDocument
        var wasObserved = false
    }
    private var historyReceipts: [String: HistoryReceipt] = [:]
    private var navigationAttemptIDs: Set<String> = []
    private var navigationDispatchLog: ComputerUseBrowserNavigationDispatchHistory?
    private var retiredNavigationOperations: [String: String] = [:]
    private struct ObservedNavigationAttempt {
        let payloadDigest: String
        var receipt: ComputerUseBrowserNavigationReceipt?
    }
    private var observedNavigationAttempts: [String: ObservedNavigationAttempt] = [:]
    private let mayAct: () -> Bool
    private let presentsWindow: Bool
    private let navigationTimeout: Duration
    private let domTimeout: Duration
    private let domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)?
    private var browser: WKWebView?
    private var window: NSWindow?
    private var urlObservation: NSKeyValueObservation?
    private var pending: PendingNavigation?
    private var pendingDOM: PendingDOM?
    private var observedNavigation: ObservedNavigation?
    private var observedUserPage: ObservedPage?
    private var observedActivePage: ObservedPage?
    private var loadedPageIdentity: String?
    private var signInBrowser: WKWebView?
    private var signInInstanceID: UUID?
    private var signInWindow: NSWindow?
    private var signInURLObservation: NSKeyValueObservation?
    private var signInScope: (taskID: String, ownerID: UUID)?

    private struct ObservedNavigation {
        let id = UUID()
        let navigation: WKNavigation
        let generation: UInt64
        let taskID: String
        let parentSessionID: UUID
        let ownershipEpoch: UUID
        let startedWhileActive: Bool
        var successfulResponseURL: URL?
    }

    private struct ObservedPage {
        enum Proof { case navigation, sameDocument(String) }
        let evidence: NavigationHistory.PageObservation
        var id: UUID { evidence.id }
        var generation: UInt64 { evidence.generation }
        let url: URL
        let proof: Proof
        var requiresExplicitHandback: Bool { evidence.requiresExplicitHandback }
    }

    private struct PendingDOM {
        let id: UUID
        let document: ComputerUseBrowserDocument?
        let capture: ComputerUseBrowserDOMReadCapture?
        var continuation: CheckedContinuation<String, Error>?
        var timeout: Task<Void, Never>?
        var completionWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct PendingNavigation {
        let id: UUID
        let taskID: String
        let generation: UInt64
        let operationID: String
        let requestedURL: URL
        let sourceAttemptID: UUID?
        let continuation: CheckedContinuation<ComputerUseBrowserDocument, Error>
        var navigation: WKNavigation?
        var successfulResponseURL: URL?
        var receivedSuccessfulResponse: Bool { successfulResponseURL != nil }
        var readOnlyRequests = true
        var historyOperationID: String?
        var instantBackApproved = false
        var restoration: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    init(presentsWindow: Bool = true, navigationTimeout: Duration = .seconds(30), domTimeout: Duration = .seconds(5),
         domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)? = nil, mayAct: @escaping () -> Bool) {
        self.presentsWindow = presentsWindow
        self.navigationTimeout = navigationTimeout
        self.domTimeout = domTimeout
        self.domScriptDidDispatch = domScriptDidDispatch
        self.mayAct = mayAct
    }

    nonisolated static func validatedURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              url.absoluteString.utf8.count <= 8_192,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let result = components.url else { return nil }
        return result
    }

    /// HTTP response identity excludes the client-side fragment (RFC 3986
    /// sections 3.5 and 6.1). This checks consistency of the response associated
    /// with an observed navigation slot, not exact response/object correlation.
    /// Retained document checks stay exact.
    nonisolated static func responseURL(_ responseURL: URL?, matchesDocumentURL documentURL: URL) -> Bool {
        guard let responseURL, let response = validatedURL(responseURL), let document = validatedURL(documentURL),
              var responseParts = URLComponents(url: response, resolvingAgainstBaseURL: false),
              var documentParts = URLComponents(url: document, resolvingAgainstBaseURL: false) else { return false }
        responseParts.fragment = nil
        documentParts.fragment = nil
        guard let responseResource = responseParts.url, let documentResource = documentParts.url else { return false }
        return responseResource == documentResource
    }

    func updateTaskControls(_ controls: ComputerUseBrowserTaskControls?,
        handler: @escaping (ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void) {
        if let scope = signInScope,
           controls?.taskID != scope.taskID || controls?.ownerID != scope.ownerID {
            closeSignInWindow(restoreParent: false)
        }
        taskControlHandler = handler
        if taskControls != controls { taskControls = controls }
    }

    func requestTaskControl(_ action: ComputerUseBrowserTaskControls.Action,
                            displayed controls: ComputerUseBrowserTaskControls) {
        // Pass the rendered snapshot unchanged. The host validates its run and
        // presentation identity; a stale view cannot select the current task.
        taskControlHandler?(controls, action)
    }

    func claim(taskID: String) throws {
        guard !hasOpenSignInWindow else { throw ComputerUseBrowserError.signInWindowOpen }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard mayAct(), !taskID.isEmpty else { throw ComputerUseBrowserError.ownershipLost }
        if self.taskID != taskID {
            retirePageObservations(.claimChanged)
            if self.taskID != nil {
                navigationDispatchLog?.recordClaim(phase: .retired, parentSessionID: browser == nil ? nil : browserSessionID,
                    ownershipEpoch: ownershipEpoch, generation: generation, retirement: .replaced)
            }
            if navigationDispatchLog?.taskID != taskID {
                navigationDispatchLog = .init(taskID: taskID, contextID: contextID,
                    beganAfterAnotherClaim: navigationDispatchLog != nil)
            }
            ownershipEpoch = UUID()
            self.taskID = taskID
            sourcePolicy = nil
            generation &+= 1
            document = nil
            receipts.removeAll()
            historyReceipts.removeAll()
            navigationAttemptIDs.removeAll()
            retiredNavigationOperations.removeAll()
            observedNavigationAttempts.removeAll()
            navigationDispatchLog?.recordClaim(phase: .claimed, parentSessionID: browser == nil ? nil : browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation)
        }
    }

    func hasOwnership(taskID: String) -> Bool { self.taskID == taskID && mayAct() && !hasOpenSignInWindow }

    var hasOpenSignInWindow: Bool { signInBrowser != nil }
    var hasSession: Bool { browser != nil }

    var isFrontmostWindow: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        return NSApp.keyWindow === window
    }

    var hasRequiredPresentation: Bool { !hasOpenSignInWindow && (!presentsWindow || isFrontmostWindow) }

    /// A new current-form request may acquire the already-open owned page.
    /// This creates an ownership token, never a new navigation receipt.
    func acquireCurrentDocument(taskID: String) throws -> ComputerUseBrowserDocument {
        guard pending == nil, pendingDOM == nil else { throw ComputerUseBrowserError.busy }
        guard mayAct(), let previous = document, browser?.isLoading == false,
              previous.generation == generation, browser?.url == previous.committedURL else { throw ComputerUseBrowserError.pageChanged }
        try claim(taskID: taskID)
        let current = ComputerUseBrowserDocument(contextID: contextID, taskID: taskID, generation: generation,
            operationID: previous.operationID, requestedURL: previous.requestedURL,
            committedURL: previous.committedURL, source: previous.source)
        document = current
        return current
    }

    /// A paused person's navigation is observable, but has no automation
    /// authority until the host accepts an authenticated explicit Resume and
    /// joins the previous executor. Merely opening the action gate is not enough.
    var isLoadingPage: Bool { browser?.isLoading == true || pending != nil || observedNavigation != nil }

    var hasPageAwaitingHandback: Bool {
        guard let observedUserPage else { return false }
        return isCurrentPageObservation(observedUserPage)
    }

    private func isCurrentPageObservation(_ page: ObservedPage) -> Bool {
        page.generation == generation && pending == nil
            && observedNavigation == nil && browser?.isLoading == false
            && browser?.url == page.url
    }

    /// A completed page may be observed after a link, form or site script
    /// navigates while this task is active. This mints no action receipt and
    /// never adopts a page changed during user control without explicit Resume.
    func acquireObservedDocument(taskID: String) async throws -> ComputerUseBrowserDocument {
        try Task.checkCancellation()
        guard let owner = self.taskID, hasOwnership(taskID: owner), let view = browser else {
            throw ComputerUseBrowserError.ownershipLost
        }
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard pending == nil else { throw ComputerUseBrowserError.busy }
        let epoch = ownershipEpoch
        let deadline = ContinuousClock.now + navigationTimeout
        while observedNavigation != nil || view.isLoading {
            try Task.checkCancellation()
            guard self.taskID == owner, ownershipEpoch == epoch, browser === view, hasOwnership(taskID: owner) else {
                throw ComputerUseBrowserError.ownershipLost
            }
            guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard self.taskID == owner, ownershipEpoch == epoch, browser === view, hasOwnership(taskID: owner) else {
            throw ComputerUseBrowserError.ownershipLost
        }
        guard pending == nil, pendingDOM == nil else { throw ComputerUseBrowserError.busy }
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        if let document, validate(document) { return try acquireCurrentDocument(taskID: taskID) }
        guard observedUserPage == nil, let observed = observedActivePage, !observed.requiresExplicitHandback else {
            throw ComputerUseBrowserError.pageChanged
        }
        try await adoptPageObservation(observed, source: .activePageObservation, taskID: taskID)
        guard let current = currentDocument(taskID: taskID) else { throw ComputerUseBrowserError.pageChanged }
        return current
    }

    func handbackRequirement(taskID: String, required: Bool = false) -> ComputerUseBrowserHandbackRequirement? {
        guard browser != nil, self.taskID == taskID else { return required ? .unavailable(taskID: taskID) : nil }
        return .init(taskID: taskID, contextID: contextID, sessionID: browserSessionID, ownershipEpoch: ownershipEpoch,
            requiresPresentation: required || hasRequiredPresentation || hasOpenSignInWindow)
    }

    private func validateSessionIdentity(_ requirement: ComputerUseBrowserHandbackRequirement, taskID: String) throws {
        guard requirement.taskID == taskID, requirement.contextID == contextID,
              requirement.sessionID == browserSessionID, requirement.ownershipEpoch == ownershipEpoch,
              browser != nil, self.taskID == taskID else { throw ComputerUseBrowserError.handbackContextLost }
    }

    private func validateHandback(_ requirement: ComputerUseBrowserHandbackRequirement, taskID: String) throws {
        try validateSessionIdentity(requirement, taskID: taskID)
        guard !hasOpenSignInWindow else { throw ComputerUseBrowserError.signInWindowOpen }
        if requirement.requiresPresentation, !hasRequiredPresentation { throw ComputerUseBrowserError.windowNotActive }
    }

    /// Allocate session identity before a workflow journal is bound. This
    /// performs no navigation or input; each child capability owns its effect.
    func prepareWorkflowSession(taskID: String) throws -> ComputerUseBrowserHandbackRequirement {
        try Task.checkCancellation()
        try claim(taskID: taskID)
        _ = makeBrowser()
        guard let requirement = handbackRequirement(taskID: taskID, required: true) else {
            throw ComputerUseBrowserError.handbackContextLost
        }
        return requirement
    }

    /// A host-admitted new research root may reuse the native view/data store.
    /// Read the actual loaded Document anew; old task evidence and receipts
    /// cannot authorize the successor. This is neither navigation nor Resume
    /// of a stopped task, and does not assert a successful earlier request.
    func admitResearchSession(taskID: String, assertAdmission: () throws -> Void) async throws -> ComputerUseBrowserHandbackRequirement {
        try Task.checkCancellation(); try assertAdmission()
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard !hasOpenSignInWindow else { throw ComputerUseBrowserError.signInWindowOpen }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil, browser?.isLoading != true else {
            throw ComputerUseBrowserError.busy
        }
        if browser == nil || hasUnnavigatedContents {
            let requirement = try prepareWorkflowSession(taskID: taskID)
            try Task.checkCancellation(); try assertAdmission()
            try validateWorkflowSession(requirement)
            return requirement
        }
        guard let view = browser, let url = view.url, Self.validatedURL(url) != nil else { throw ComputerUseBrowserError.pageChanged }
        let previousOwner = self.taskID, epoch = ownershipEpoch, revision = locationRevision, generation = self.generation
        func isCurrent() -> Bool {
            !Task.isCancelled && (try? assertAdmission()) != nil && mayAct() && !hasOpenSignInWindow
                && browser === view && self.taskID == previousOwner && ownershipEpoch == epoch
                && locationRevision == revision && self.generation == generation && view.url == url && !view.isLoading
                && pending == nil && observedNavigation == nil
        }
        guard isCurrent() else { throw ComputerUseBrowserError.handbackContextLost }
        presentIfNeeded(view)
        let deadline = ContinuousClock.now + .seconds(2)
        while !hasRequiredPresentation && ContinuousClock.now < deadline {
            try Task.checkCancellation(); try assertAdmission()
            guard isCurrent() else { throw ComputerUseBrowserError.pageChanged }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation(); try assertAdmission()
        guard isCurrent() else { throw ComputerUseBrowserError.pageChanged }
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let identity = try await readPageIdentity(validateContext: { isCurrent() && self.hasRequiredPresentation })
        try Task.checkCancellation(); try assertAdmission()
        guard isCurrent(), hasRequiredPresentation, pendingDOM == nil else { throw ComputerUseBrowserError.pageChanged }
        try claim(taskID: taskID)
        document = ComputerUseBrowserDocument(contextID: contextID, taskID: taskID, generation: self.generation,
            operationID: "task-admission-\(UUID().uuidString)", requestedURL: url, committedURL: url, source: .taskAdmissionObservation)
        loadedPageIdentity = identity
        retirePageObservations(.taskAdmission)
        guard let requirement = handbackRequirement(taskID: taskID, required: true) else { throw ComputerUseBrowserError.handbackContextLost }
        try validateWorkflowSession(requirement)
        detail = "Checking the page for the new request"
        return requirement
    }

    func validateWorkflowSession(_ requirement: ComputerUseBrowserHandbackRequirement) throws {
        try Task.checkCancellation()
        try validateSessionIdentity(requirement, taskID: requirement.taskID)
        guard hasOwnership(taskID: requirement.taskID) else { throw ComputerUseBrowserError.ownershipLost }
    }

    func installSourcePolicy(_ policy: ComputerUseBrowserSourcePolicy, replacing expectedDigest: String?,
                             session: ComputerUseBrowserHandbackRequirement) throws {
        try validateWorkflowSession(session)
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard policy.taskID == session.taskID, sourcePolicy?.digest == expectedDigest else { throw ComputerUseBrowserError.pageChanged }
        try Task.checkCancellation()
        try validateSessionIdentity(session, taskID: session.taskID)
        if sourcePolicy != policy {
            let previousPolicy = sourcePolicy
            sourcePolicy = policy
            navigationDispatchLog?.recordPolicyInstallation(parentSessionID: browserSessionID, ownershipEpoch: ownershipEpoch,
                generation: generation, previousPolicy: previousPolicy, policy: policy)
        }
    }

    func validateSourcePolicy(_ expected: ComputerUseBrowserSourcePolicy?, session: ComputerUseBrowserHandbackRequirement) throws {
        try validateSessionIdentity(session, taskID: session.taskID)
        guard sourcePolicy == expected else { throw ComputerUseBrowserError.pageChanged }
    }

    private func validateSourceURL(_ url: URL) throws {
        guard sourcePolicy?.permits(url) != false else { throw ComputerUseBrowserError.sourceNotAllowed }
    }

    func validateSourceDocument(_ expected: ComputerUseBrowserDocument) throws {
        try Task.checkCancellation()
        guard validate(expected) else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceURL(expected.committedURL)
    }

    private var hasUnnavigatedContents: Bool {
        guard let browser else { return false }
        return !sessionHasNavigationActivity && browser.url == nil && !browser.isLoading
            && pending == nil && pendingDOM == nil && observedNavigation == nil
            && document == nil && loadedPageIdentity == nil && receipts.isEmpty
            && observedUserPage == nil && observedActivePage == nil && !hasOpenSignInWindow
    }

    /// Native evidence of an allocated session with no navigation activity.
    /// This is not a page observation, receipt or permission to reset a journal.
    func isUnnavigatedSession(_ requirement: ComputerUseBrowserHandbackRequirement) throws -> Bool {
        try validateWorkflowSession(requirement)
        return hasUnnavigatedContents
    }

    /// Called by a workflow after its state transition, not by page content.
    /// Recording is observational and does not query or reopen the action gate.
    func recordWorkflowControl(_ phase: ComputerUseBrowserNavigationDispatchHistory.ControlPhase,
                               requirement: ComputerUseBrowserHandbackRequirement, operationID: UUID? = nil) {
        guard [.workflowPaused, .workflowResumeStarted, .workflowContextAdmitted, .workflowResumed, .workflowResumeFailed].contains(phase) else { return }
        recordBoundControl(phase, requirement: requirement, workflowOperationID: operationID)
    }

    private func recordBoundControl(_ phase: NavigationHistory.ControlPhase, requirement: ComputerUseBrowserHandbackRequirement,
                                    workflowOperationID: UUID? = nil, nativeOperationID: UUID? = nil) {
        do { try validateSessionIdentity(requirement, taskID: requirement.taskID) } catch { return }
        navigationDispatchLog?.recordControl(phase: phase, parentSessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: browser?.url,
            handback: requirement, workflowOperationID: workflowOperationID,
            nativeOperationID: nativeOperationID, signInWindowID: signInInstanceID)
    }

    func reacquireAfterUserControl(taskID: String, requirement: ComputerUseBrowserHandbackRequirement,
                                  workflowOperationID: UUID? = nil) async throws {
        try Task.checkCancellation()
        try validateSessionIdentity(requirement, taskID: taskID)
        let id = UUID()
        recordBoundControl(.nativeReacquisitionStarted, requirement: requirement,
            workflowOperationID: workflowOperationID, nativeOperationID: id)
        do {
            try await performNativeHandback(taskID: taskID, requirement: requirement, nativeOperationID: id)
            recordBoundControl(.nativeReacquisitionFinished, requirement: requirement,
                workflowOperationID: workflowOperationID, nativeOperationID: id)
        } catch {
            recordBoundControl(.nativeReacquisitionFailed, requirement: requirement,
                workflowOperationID: workflowOperationID, nativeOperationID: id)
            throw error
        }
    }

    private func performNativeHandback(taskID: String, requirement: ComputerUseBrowserHandbackRequirement, nativeOperationID: UUID) async throws {
        if hasUnnavigatedContents, let browser {
            guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
            try Task.checkCancellation()
            try validateSessionIdentity(requirement, taskID: taskID)
            // First-page preparation can allocate a session before presenting
            // its window. Explicit Resume may present that same blank browser.
            presentIfNeeded(browser)
            let focusDeadline = ContinuousClock.now + .seconds(2)
            while requirement.requiresPresentation && !hasRequiredPresentation && ContinuousClock.now < focusDeadline {
                try Task.checkCancellation()
                try validateWorkflowSession(requirement)
                guard hasUnnavigatedContents else { throw ComputerUseBrowserError.pageChanged }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            try validateWorkflowSession(requirement)
            try validateHandback(requirement, taskID: taskID)
            guard hasOwnership(taskID: taskID), hasUnnavigatedContents else { throw ComputerUseBrowserError.pageChanged }
            detail = "Control returned — ready to open the first page"
            return
        }
        try validateHandback(requirement, taskID: taskID)
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil,
              browser?.isLoading == false else { throw ComputerUseBrowserError.busy }
        // An unchanged document needs no new navigation or invented receipt.
        if let document, validate(document) { return }
        if let observed = observedUserPage {
            try await adoptPageObservation(observed, source: .userControlObservation, taskID: taskID, nativeReacquisitionID: nativeOperationID)
        } else if let observed = observedActivePage {
            // A page observed during automation remains that kind of evidence
            // when explicitly handed back later. It is never an action receipt.
            try await adoptPageObservation(observed, source: .activePageObservation, taskID: taskID, nativeReacquisitionID: nativeOperationID)
        } else { throw ComputerUseBrowserError.pageChanged }
        try validateHandback(requirement, taskID: taskID)
        detail = "Control returned — checking the current page"
    }

    private func adoptPageObservation(_ observed: ObservedPage, source: ComputerUseBrowserDocument.Source,
                                      taskID: String, nativeReacquisitionID: UUID? = nil) async throws {
        guard source != .automationNavigation, isCurrentPageObservation(observed) else { throw ComputerUseBrowserError.pageChanged }
        let owner = self.taskID, view = browser, epoch = ownershipEpoch
        func isCurrentObservation() -> Bool {
            let retained = source == .userControlObservation ? observedUserPage : observedActivePage
            return mayAct() && self.taskID == owner && ownershipEpoch == epoch && browser === view && !hasOpenSignInWindow
                && (source != .activePageObservation || hasRequiredPresentation)
                && retained?.id == observed.id && isCurrentPageObservation(observed)
        }
        let identity: String?
        do {
            identity = try await readPageIdentity(validateContext: isCurrentObservation)
        } catch {
            try Task.checkCancellation()
            guard isCurrentObservation() else { throw ComputerUseBrowserError.pageChanged }
            // A completed HTTP navigation remains independently observable
            // for non-DOM content. History changes require identity proof.
            guard case .navigation = observed.proof else { throw error }
            identity = nil
        }
        try Task.checkCancellation()
        guard isCurrentObservation() else { throw ComputerUseBrowserError.pageChanged }
        if case .sameDocument(let expectedIdentity) = observed.proof, identity != expectedIdentity {
            retirePageObservations(.identityMismatch)
            loadedPageIdentity = nil
            throw ComputerUseBrowserError.pageChanged
        }
        try claim(taskID: taskID)
        document = ComputerUseBrowserDocument(contextID: contextID, taskID: taskID,
            generation: generation, operationID: "page-observation-\(observed.id.uuidString)",
            requestedURL: observed.url, committedURL: observed.url, source: source)
        // Claim may transfer the page to a different task. Retain the original
        // accepted identity in that task's log; never invent an earlier event.
        recordPageObservation(.adopted, page: observed, adoptedSource: source, nativeReacquisitionID: nativeReacquisitionID)
        // This observation is deliberately absent from `receipts`. The URL
        // records observed location, not a requested/executed navigation.
        observedUserPage = nil
        observedActivePage = nil
        loadedPageIdentity = identity
        detail = "Checking the current page"
    }

    func callDOM(_ command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                 document expected: ComputerUseBrowserDocument, retaining capture: ComputerUseBrowserDOMReadCapture? = nil) async throws -> ComputerUseBrowserDOMReply {
        try await callDOM(command, arguments: arguments, document: expected, retaining: capture, validateContext: { self.validate(expected) })
    }

    func observePage(document expected: ComputerUseBrowserDocument, includingControlState: Bool = false) async throws -> ComputerUseBrowserPageEvidence {
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let result = try await callDOM(.pageSnapshot, arguments: includingControlState ? ["includeControlState":true] : [:], document: expected)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard result.status == "page-snapshot", result.fields == nil,
              let page = result.page, page.isWellFormed, page.controlStateObserved == includingControlState,
              page.scopedControlIDs.isEmpty else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        if historyReceipts[expected.operationID]?.document == expected { historyReceipts[expected.operationID]?.wasObserved = true }
        return ComputerUseBrowserPageEvidence(document: expected, documentID: result.documentID, page: page)
    }

    /// The browser/document gate is rechecked around WebKit's await; the
    /// script separately re-reads text, rendering and destinations. A fresh
    /// read replaces the prior observation rather than extending its lease.
    func validatePageEvidence(_ evidence: ComputerUseBrowserPageEvidence) async throws {
        try validateSourceDocument(evidence.document)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let result = try await callDOM(.validatePageSnapshot,
            arguments: ["documentID": evidence.documentID, "snapshotID": evidence.page.id], document: evidence.document)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard result.status == "page-current", result.documentID == evidence.documentID,
              result.fields == nil, result.page == nil else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceDocument(evidence.document)
    }

    func prepareLinkNavigation(linkID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        guard evidence.page.isWellFormed,
              let link = evidence.page.links.first(where: { $0.id == linkID }),
              let destination = URL(string: link.destination).flatMap(Self.validatedURL) else {
            throw ComputerUseBrowserError.linkNavigationUnavailable
        }
        let target = ComputerUseBrowserNavigationTarget(evidence: evidence, source: .link(linkID), destination: destination,
            sourcePolicyDigest: sourcePolicy?.digest)
        try await validateObservedDestination(target)
        return target
    }

    func prepareFormQuery(controlID: String, evidence: ComputerUseBrowserPageEvidence,
                          requirements: ComputerUseBrowserFormQueryRequirements? = nil) async throws -> ComputerUseBrowserNavigationTarget {
        guard evidence.page.isWellFormed, evidence.page.controls.contains(where: { $0.id == controlID && $0.kind == "submit" && !$0.disabled }),
              hasRequiredPresentation else { throw ComputerUseBrowserError.formQueryUnavailable }
        var arguments: [String: Any] = ["documentID": evidence.documentID, "snapshotID": evidence.page.id, "controlID": controlID]
        if let requirements {
            guard requirements.document == evidence.document, requirements.documentID == evidence.documentID else {
                throw ComputerUseBrowserError.pageChanged
            }
            arguments["requirements"] = requirements.domArguments
        }
        let result = try await callDOM(.prepareFormQuery, arguments: arguments, document: evidence.document)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        if result.status == "form-invalid" { throw ComputerUseBrowserError.formQueryInvalid }
        guard result.status == "form-query-prepared", result.documentID == evidence.documentID, result.fields == nil,
              result.page == nil, let query = result.formQuery, query.isWellFormed, query.controlID == controlID,
              let destination = URL(string: query.destination).flatMap(Self.validatedURL),
              Self.sameOrigin(destination, evidence.document.committedURL) else {
            throw ComputerUseBrowserError.formQueryUnavailable
        }
        return .init(evidence: evidence, source: .formQuery(controlID: controlID, queryID: query.id,
            requirementsDigest: requirements?.digest), destination: destination, sourcePolicyDigest: sourcePolicy?.digest)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }

    func historyOptions(goal: ComputerUseBrowserGoalInput, visits: [ComputerUseBrowserResearchVisit],
                        evidence: ComputerUseBrowserPageEvidence) throws -> [ComputerUseBrowserHistoryOption] {
        try validateSourceDocument(evidence.document)
        guard evidence.document.taskID == goal.taskID, visits.count <= 64,
              visits.allSatisfy({ $0.rootDigest == goal.rootDigest }) else { throw ComputerUseBrowserError.observedNavigationUnavailable }
        var options: [ComputerUseBrowserHistoryOption] = [], seen: Set<String> = []
        for (index, visit) in visits.enumerated().reversed() {
            guard let saved = historyReceipts[visit.operationID], saved.url != evidence.document.committedURL,
                  seen.insert(saved.url.absoluteString).inserted,
                  let option = try? historyOption(visit: index, operationID: visit.operationID, evidence: evidence) else { continue }
            options.append(option)
        }
        return options.sorted { $0.visit < $1.visit }
    }

    func historyOption(visit: Int, operationID: String, evidence: ComputerUseBrowserPageEvidence) throws -> ComputerUseBrowserHistoryOption {
        try validateSourceDocument(evidence.document)
        guard let browser, let saved = historyReceipts[operationID], saved.wasObserved, receipts[operationID] == saved.document,
              saved.document.taskID == evidence.document.taskID, saved.document.contextID == evidence.document.contextID,
              saved.item.url == saved.url, Self.validatedURL(saved.url) != nil,
              browser.backForwardList.currentItem !== saved.item else { throw ComputerUseBrowserError.observedNavigationUnavailable }
        try validateSourceURL(saved.url)
        let mode: ComputerUseBrowserHistoryOption.Mode
        if browser.backForwardList.backList.contains(where: { $0 === saved.item }) { mode = .back }
        else if browser.backForwardList.forwardList.contains(where: { $0 === saved.item }) { mode = .forward }
        else { mode = .revisit }
        return .init(visit: visit, operationID: operationID, mode: mode,
            target: .init(evidence: evidence, source: mode == .revisit ? .revisit(operationID) : .history(operationID),
                destination: saved.url, sourcePolicyDigest: sourcePolicy?.digest))
    }

    func validateHistoryRefresh(_ previous: ComputerUseBrowserNavigationTarget, replacement: ComputerUseBrowserNavigationTarget) throws {
        guard previous.source == replacement.source, previous.destination == replacement.destination,
              previous.contextID == replacement.contextID, previous.taskID == replacement.taskID,
              previous.sourcePolicyDigest == replacement.sourcePolicyDigest else { throw ComputerUseBrowserError.pageChanged }
        switch previous.source { case .history, .revisit: break; default: throw ComputerUseBrowserError.observedNavigationUnavailable }
    }

    private func historyItem(for target: ComputerUseBrowserNavigationTarget) throws -> WKBackForwardListItem? {
        let operationID: String, usesHistory: Bool
        switch target.source {
        case .history(let id): operationID = id; usesHistory = true
        case .revisit(let id): operationID = id; usesHistory = false
        default: return nil
        }
        let fresh = try historyOption(visit: 0, operationID: operationID, evidence: target.evidence)
        try validateHistoryRefresh(target, replacement: fresh.target)
        return usesHistory ? historyReceipts[operationID]?.item : nil
    }

    /// A proven-unsent research query may refresh its page nonce. Keep the
    /// exact private destination, submitter reference and verified edit contract;
    /// equal visible labels cannot authorize changed query parameters or action.
    func validateFormQueryRefresh(_ previous: ComputerUseBrowserNavigationTarget,
                                  replacement: ComputerUseBrowserNavigationTarget) throws {
        guard case .formQuery(let beforeControl, _, let beforeRequirements) = previous.source,
              case .formQuery(let afterControl, _, let afterRequirements) = replacement.source,
              beforeRequirements != nil, beforeRequirements == afterRequirements, beforeControl == afterControl,
              previous.evidence.document == replacement.evidence.document,
              previous.evidence.documentID == replacement.evidence.documentID,
              previous.destination.absoluteString.utf8.elementsEqual(replacement.destination.absoluteString.utf8),
              previous.sourcePolicyDigest == replacement.sourcePolicyDigest else {
            throw ComputerUseBrowserError.formQueryUnavailable
        }
    }

    /// Read-only validation, also used before durably rebinding an unsent plan.
    func validateObservedDestination(_ target: ComputerUseBrowserNavigationTarget) async throws {
        guard target.sourcePolicyDigest == sourcePolicy?.digest else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceURL(target.destination)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let evidence = target.evidence
        var arguments: [String: Any] = ["documentID": evidence.documentID, "snapshotID": evidence.page.id]
        let command: ComputerUseBrowserDOMCommand, expectedStatus: String
        switch target.source {
        case .link(let id): arguments["linkID"] = id; command = .validatePageLink; expectedStatus = "link-current"
        case .history, .revisit:
            _ = try historyItem(for: target)
            command = .validatePageSnapshot; expectedStatus = "page-current"
        case .formQuery(let controlID, let queryID, let requirementsDigest):
            arguments["controlID"] = controlID; arguments["queryID"] = queryID
            if let requirementsDigest { arguments["requirementsDigest"] = requirementsDigest }
            command = .validateFormQuery; expectedStatus = "form-query-current"
        }
        let result: ComputerUseBrowserDOMReply
        do { result = try await callDOM(command, arguments: arguments, document: evidence.document) }
        catch {
            // Cancellation/timeout can precede WebKit's completion callback.
            // Retain the caller's operation until that callback has joined.
            await joinDOMCompletion(document: evidence.document)
            throw error
        }
        _ = try historyItem(for: target)
        guard target.sourcePolicyDigest == sourcePolicy?.digest else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceURL(target.destination)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        if result.status == "form-invalid" { throw ComputerUseBrowserError.formQueryInvalid }
        guard result.status == expectedStatus, result.documentID == evidence.documentID,
              result.fields == nil, result.page == nil else {
            if case .formQuery = target.source { throw ComputerUseBrowserError.formQueryUnavailable }
            throw ComputerUseBrowserError.linkNavigationUnavailable
        }
    }

    /// Absence of a receipt is not absence of an attempt. Keep failures before
    /// native load conservative too: the durable callback may have failed.
    func hasObservedNavigationAttempt(operationID: String) -> Bool {
        hasNavigationAttempt(operationID: operationID)
    }

    func validateUnretiredNavigation(operationID: String) throws {
        guard retiredNavigationOperations[operationID] == nil else { throw ComputerUseBrowserError.observedNavigationRetired }
    }

    /// Synchronous native no-attempt proof and revocation. The caller holds
    /// the original operation's disk execution lease until its tombstone is
    /// durable. Stale document references can be retired, never dispatched.
    func retireUnsentObservedDestination(_ target: ComputerUseBrowserNavigationTarget, operationID: String) throws -> Bool {
        try Task.checkCancellation()
        guard hasOwnership(taskID: target.taskID), target.contextID == contextID else { throw ComputerUseBrowserError.ownershipLost }
        guard operationID.utf8.count == 64, operationID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.observedNavigationUnavailable
        }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard !hasNavigationAttempt(operationID: operationID) else { return false }
        if let retired = retiredNavigationOperations[operationID] {
            guard retired == target.payloadDigest else { throw ComputerUseBrowserError.observedNavigationRetired }
            return true
        }
        guard retiredNavigationOperations.count < 64 else { throw ComputerUseBrowserError.observedNavigationUnavailable }
        retiredNavigationOperations[operationID] = target.payloadDigest
        return true
    }

    /// Open the previously bound HTTP(S) destination with the native browser
    /// loader. This intentionally has navigation semantics, not DOM click
    /// semantics: it dispatches no click, submit, formdata, or invalid event.
    /// A returned receipt proves one navigation, never the complete task.
    func openObservedDestination(_ target: ComputerUseBrowserNavigationTarget, operationID: String,
                             willBeginEffect: () throws -> Void = {}) async throws -> ComputerUseBrowserNavigationReceipt {
        try Task.checkCancellation()
        guard hasOwnership(taskID: target.evidence.document.taskID),
              target.evidence.document.contextID == contextID else { throw ComputerUseBrowserError.ownershipLost }
        guard operationID.utf8.count == 64,
              operationID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.observedNavigationUnavailable
        }
        try validateUnretiredNavigation(operationID: operationID)
        if let attempted = observedNavigationAttempts[operationID] {
            guard attempted.payloadDigest == target.payloadDigest, let receipt = attempted.receipt else {
                throw ComputerUseBrowserError.observedNavigationUncertain
            }
            return receipt
        }
        guard observedNavigationAttempts.count < 64 else { throw ComputerUseBrowserError.observedNavigationUnavailable }
        try await validateObservedDestination(target)
        do {
            let historyTarget: ComputerUseBrowserNavigationTarget?
            switch target.source { case .history, .revisit: historyTarget = target; default: historyTarget = nil }
            let document = try await performNavigation(taskID: target.evidence.document.taskID, operationID: operationID,
                to: target.destination, from: target.evidence.document, willBeginEffect: {
                    self.observedNavigationAttempts[operationID] = ObservedNavigationAttempt(payloadDigest: target.payloadDigest)
                    try willBeginEffect()
                }, historyTarget: historyTarget)
            let receipt = ComputerUseBrowserNavigationReceipt(payloadDigest: target.payloadDigest, document: document)
            observedNavigationAttempts[operationID]?.receipt = receipt
            return receipt
        } catch {
            // didFinish may have proved the native load before cancellation
            // interrupts subsequent document-identity observation. Keep that
            // fact without changing the interrupted caller's result.
            if observedNavigationAttempts[operationID]?.payloadDigest == target.payloadDigest,
               let document = receipts[operationID], document.contextID == contextID,
               document.taskID == target.evidence.document.taskID, document.requestedURL == target.destination {
                observedNavigationAttempts[operationID]?.receipt = .init(payloadDigest: target.payloadDigest, document: document)
            }
            throw error
        }
    }

    /// Historical native evidence only. Reading it cannot start a request or
    /// establish that the destination is still the current page. Control may
    /// already have changed while a caller saves a late confirmed fact.
    func observedNavigationReceipt(for target: ComputerUseBrowserNavigationTarget,
                                   operationID: String) -> ComputerUseBrowserNavigationReceipt? {
        guard target.contextID == contextID, target.taskID == taskID,
              let attempt = observedNavigationAttempts[operationID], attempt.payloadDigest == target.payloadDigest,
              let receipt = attempt.receipt, receipt.payloadDigest == target.payloadDigest,
              receipt.document.contextID == contextID, receipt.document.taskID == target.taskID,
              receipt.document.operationID == operationID, receipt.document.requestedURL == target.destination else { return nil }
        return receipt
    }

    func scrollViewport(_ direction: OSAtlasScrollDirection, evidence: ComputerUseBrowserPageEvidence,
                        operationID: String, willBeginEffect: () -> Void = {}) async throws -> ComputerUseBrowserViewportScrollReceipt {
        try Task.checkCancellation()
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard validate(evidence.document) else { throw ComputerUseBrowserError.pageChanged }
        guard let before = evidence.page.viewport, before.isWellFormed,
              operationID.utf8.count == 64,
              operationID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.viewportScrollUnavailable
        }
        // The caller retains an uncertain effect before WebKit can execute.
        // A lost/cancelled callback cannot authorize a wheel fallback or replay.
        willBeginEffect()
        do {
            let result = try await callDOM(.scrollViewport, arguments: [
                "documentID": evidence.documentID, "snapshotID": evidence.page.id,
                "operationID": operationID, "direction": direction.rawValue],
                validateContext: { self.hasRequiredPresentation && self.validate(evidence.document) })
            guard result.status == "viewport-scroll-dispatched", result.documentID == evidence.documentID,
                  result.fields == nil, result.page == nil, let receipt = result.scroll,
                  receipt.validates(operationID: operationID, direction: direction, before: before) else {
                throw ComputerUseBrowserError.viewportScrollUncertain
            }
            // Re-read on a separate invocation, after page scroll handlers had
            // an opportunity to run. This is not a general page-settled proof.
            let confirmation = try await callDOM(.viewportScrollReceipt,
                arguments: ["documentID": evidence.documentID, "operationID": operationID],
                validateContext: { self.hasRequiredPresentation && self.validate(evidence.document) })
            guard confirmation.status == "viewport-scroll-confirmed", confirmation.documentID == evidence.documentID,
                  confirmation.fields == nil, confirmation.page == nil, confirmation.scroll == receipt else {
                throw ComputerUseBrowserError.viewportScrollUncertain
            }
            return receipt
        } catch is CancellationError { throw CancellationError() }
        catch ComputerUseBrowserError.authenticationRequired { throw ComputerUseBrowserError.authenticationRequired }
        catch { throw ComputerUseBrowserError.viewportScrollUncertain }
    }

    private func readPageIdentity(validateContext: () -> Bool) async throws -> String {
        let reply = try await callDOM(.pageIdentity, arguments: [:], validateContext: validateContext)
        guard reply.status == "page-identity", reply.fields == nil else { throw ComputerUseBrowserError.pageChanged }
        return reply.documentID
    }

    private func callDOM(_ command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                         document: ComputerUseBrowserDocument? = nil,
                         retaining capture: ComputerUseBrowserDOMReadCapture? = nil,
                         validateContext: () -> Bool) async throws -> ComputerUseBrowserDOMReply {
        try Task.checkCancellation()
        guard validateContext(), let browser else { throw ComputerUseBrowserError.pageChanged }
        guard pendingDOM == nil else { throw ComputerUseBrowserError.busy }
        if let retained = try capture?.retainedReply(command: command, arguments: arguments, document: document) { return retained }
        let id = UUID()
        let source = try await withTaskCancellationHandler {
            do {
                let source: String = try await withCheckedThrowingContinuation { continuation in
                    do { try capture?.begin(command: command, arguments: arguments, document: document) }
                    catch { continuation.resume(throwing: error); return }
                    pendingDOM = PendingDOM(id: id, document: document, capture: capture, continuation: continuation)
                    pendingDOM?.timeout = Task { [weak self, domTimeout] in
                        do { try await Task.sleep(for: domTimeout) } catch { return }
                        self?.interruptDOM(id: id, error: ComputerUseBrowserError.documentUnresponsive)
                    }
                    browser.callAsyncJavaScript(ComputerUseBrowserDOM.invocation,
                        arguments: ["command": command.rawValue, "args": arguments], in: nil, in: ComputerUseBrowserDOM.world) { [weak self] result in
                        guard let self, let pending = pendingDOM, pending.id == id else { return }
                        pendingDOM = nil
                        pending.timeout?.cancel()
                        defer { for waiter in pending.completionWaiters { waiter.resume() } }
                        switch result {
                        case .success(let value):
                            guard let source = value as? String, source.utf8.count <= 8 * 1_024 * 1_024 else {
                                pending.capture?.finish(.failure(ComputerUseBrowserError.unsupportedDocument))
                                pending.continuation?.resume(throwing: ComputerUseBrowserError.unsupportedDocument)
                                return
                            }
                            pending.capture?.finish(Result { try Self.decodeDOMReply(source, command: command) })
                            pending.continuation?.resume(returning: source)
                        case .failure:
                            pending.capture?.finish(.failure(ComputerUseBrowserError.pageChanged))
                            pending.continuation?.resume(throwing: ComputerUseBrowserError.pageChanged)
                        }
                    }
                    domScriptDidDispatch?(command)
                }
                try Task.checkCancellation()
                return source
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.interruptDOM(id: id, error: CancellationError()) }
        }
        guard validateContext() else { throw ComputerUseBrowserError.pageChanged }
        return try Self.decodeDOMReply(source, command: command)
    }

    static func decodeDOMReply(_ source: String, command: ComputerUseBrowserDOMCommand) throws -> ComputerUseBrowserDOMReply {
        let result = try JSONDecoder().decode(ComputerUseBrowserDOMReply.self, from: Data(source.utf8))
        if command == .inspectPreparedRevision || result.recoveredRevisionID != nil {
            guard command == .inspectPreparedRevision,
                  result.page == nil, result.scroll == nil, result.formQuery == nil, result.formStateProof == nil,
                  result.formBindings == nil, result.formPreservation == nil, result.changedFieldIDs == nil,
                  result.popupBinding == nil, result.popupReceipt == nil, result.popupControls == nil,
                  result.popupPreservedControls == nil, result.optionSelectionBinding == nil, result.optionSelectionReceipt == nil,
                  result.selectionPreservedControls == nil, result.optionSelectionCandidates == nil else {
                throw ComputerUseBrowserError.unsupportedDocument
            }
            if result.status == "ok" || result.status == "revision-not-captured" {
                guard let id = result.recoveredRevisionID, id.utf8.count == 64,
                      id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let ledger = result.inputLedgerID, ledger.utf8.count == 32,
                      ledger.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      result.status == "ok" ? result.fields?.isEmpty == false && result.uncapturedRevisionID == nil
                        : result.fields == nil && result.uncapturedRevisionID == id else {
                    throw ComputerUseBrowserError.unsupportedDocument
                }
            } else {
                guard result.recoveredRevisionID == nil, result.fields == nil, result.uncapturedRevisionID == nil else {
                    throw ComputerUseBrowserError.unsupportedDocument
                }
            }
        }
        if result.status == "revision-not-captured" || result.uncapturedRevisionID != nil {
            guard command == .reviseFormFields || command == .inspectPreparedRevision, result.status == "revision-not-captured",
                  let revisionID = result.uncapturedRevisionID, revisionID.utf8.count == 64,
                  revisionID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let ledger = result.inputLedgerID, ledger.utf8.count == 32,
                  ledger.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  result.fields == nil, result.page == nil, result.scroll == nil, result.formQuery == nil,
                  result.formStateProof == nil, result.formBindings == nil, result.formPreservation == nil,
                  result.changedFieldIDs == nil, result.popupBinding == nil, result.popupReceipt == nil,
                  result.popupControls == nil, result.popupPreservedControls == nil, result.optionSelectionBinding == nil,
                  result.optionSelectionReceipt == nil, result.selectionPreservedControls == nil,
                  result.optionSelectionCandidates == nil else { throw ComputerUseBrowserError.unsupportedDocument }
        }
        guard result.scroll == nil || command == .scrollViewport || command == .viewportScrollReceipt else {
            throw ComputerUseBrowserError.unsupportedDocument
        }
        guard result.formQuery == nil || command == .prepareFormQuery else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.formStateProof == nil || command == .verifyFormState else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.formBindings == nil || command == .bindPageFields else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.formPreservation == nil || command == .prepareFormPreservation else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.changedFieldIDs == nil || command == .inspectFormRequirements else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.popupBinding == nil || command == .preparePopup,
              result.popupReceipt == nil || command == .popupReceipt,
              result.popupControls == nil || command == .popupCandidates,
              result.popupPreservedControls == nil || command == .preparePopup else { throw ComputerUseBrowserError.unsupportedDocument }
        guard result.optionSelectionBinding == nil || command == .prepareOptionSelection,
              result.optionSelectionReceipt == nil || command == .optionSelectionReceipt,
              result.optionSelectionCandidates == nil || command == .optionSelectionCandidates,
              result.selectionPreservedControls == nil || command == .prepareOptionSelection else { throw ComputerUseBrowserError.unsupportedDocument }
        if [.verifyFormState, .validateFormState, .popupCandidates, .preparePopup, .validatePopup, .openPopup, .popupReceipt, .retireUnsentPopup,
            .optionSelectionCandidates, .prepareOptionSelection, .validateOptionSelection, .selectOption, .optionSelectionReceipt, .retireUnsentOptionSelection].contains(command) {
            guard result.fields == nil, result.page == nil, result.scroll == nil, result.formQuery == nil,
                  result.formBindings == nil, result.changedFieldIDs == nil else { throw ComputerUseBrowserError.unsupportedDocument }
        }
        guard result.documentID.utf8.count == 32,
              result.documentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.pageChanged
        }
        if result.status == "authentication-required" {
            guard result.formPreservation == nil, result.formStateProof == nil else { throw ComputerUseBrowserError.unsupportedDocument }
            guard result.fields == nil, result.page == nil, result.scroll == nil, result.formQuery == nil,
                  result.formBindings == nil, result.changedFieldIDs == nil, result.popupBinding == nil, result.popupReceipt == nil,
                  result.popupControls == nil, result.popupPreservedControls == nil, result.optionSelectionBinding == nil, result.optionSelectionReceipt == nil,
                  result.selectionPreservedControls == nil, result.optionSelectionCandidates == nil else { throw ComputerUseBrowserError.unsupportedDocument }
            throw ComputerUseBrowserError.authenticationRequired
        }
        return result
    }

    /// Cleanup only: retain an executor's lease until already-dispatched work
    /// on its document returns, or that browser is released. Cancellation and
    /// login/control loss cannot turn a pending native call into an idle one.
    /// An unresponsive page must be closed to release work that never returns.
    func joinDOMCompletion(document expected: ComputerUseBrowserDocument) async {
        guard let pending = pendingDOM, pending.document == expected else { return }
        await withCheckedContinuation { continuation in
            guard pendingDOM?.id == pending.id else { continuation.resume(); return }
            pendingDOM?.completionWaiters.append(continuation)
        }
    }

    /// A cancelled caller cannot retract a WebKit script. A continuation of
    /// the same document may wait for that callback before observing again;
    /// ownership and cancellation remain checked throughout this bounded wait.
    func waitForDOMCompletion(document expected: ComputerUseBrowserDocument) async throws {
        let deadline = ContinuousClock.now + domTimeout
        while pendingDOM != nil {
            try Task.checkCancellation()
            guard validate(expected) else { throw ComputerUseBrowserError.pageChanged }
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard validate(expected) else { throw ComputerUseBrowserError.pageChanged }
    }

    private func interruptDOM(id: UUID, error: Error) {
        guard var pending = pendingDOM, pending.id == id else { return }
        let continuation = pending.continuation
        pending.continuation = nil
        pending.timeout?.cancel()
        pending.timeout = nil
        pendingDOM = pending
        // WebKit cannot retract an already dispatched script. Keep its slot
        // occupied until callback/close, so another task cannot overtake it.
        continuation?.resume(throwing: error)
    }

    func receipt(taskID: String, operationID: String) -> ComputerUseBrowserDocument? {
        guard hasOwnership(taskID: taskID) else { return nil }
        return receipts[operationID]
    }

    /// Independent native dispatch history. Journal refresh must not treat a
    /// missing receipt or an earlier planned file as proof of no request.
    func hasNavigationAttempt(operationID: String) -> Bool {
        navigationAttemptIDs.contains(operationID) || receipts[operationID] != nil || observedNavigationAttempts[operationID] != nil
    }

    /// Read a value snapshot under current ownership. A missing configured
    /// policy, failed attempt or claim boundary remains explicit. This API
    /// certifies neither redirect coverage nor absence of other navigation.
    func navigationDispatchHistory(taskID: String) throws -> ComputerUseBrowserNavigationDispatchHistory {
        guard hasOwnership(taskID: taskID), let navigationDispatchLog, navigationDispatchLog.taskID == taskID else {
            throw ComputerUseBrowserError.ownershipLost
        }
        return navigationDispatchLog
    }

    /// Historical receipt binding only. Do not query the action gate here:
    /// an owner must retain a completed child's fact even if Pause arrived
    /// before its outer return. A retired claim cannot bind a replacement.
    func confirmedNavigationAttempt(for document: ComputerUseBrowserDocument) -> ComputerUseBrowserNavigationDispatchHistory.Attempt? {
        guard document.source == .automationNavigation, document.taskID == taskID, document.contextID == contextID,
              receipts[document.operationID] == document,
              let history = navigationDispatchLog, history.taskID == document.taskID else { return nil }
        let matches = history.attempts.filter {
            $0.operationID == document.operationID && $0.sessionID == browserSessionID && $0.ownershipEpoch == ownershipEpoch
                && $0.generation == document.generation && $0.outcome == .documentCommitted && $0.terminalOrder != nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func currentDocument(taskID: String) -> ComputerUseBrowserDocument? {
        guard hasOwnership(taskID: taskID), pending == nil, let document,
              document.generation == generation, browser?.isLoading == false,
              browser?.url == document.committedURL else { return nil }
        return document
    }

    func validate(_ expected: ComputerUseBrowserDocument) -> Bool {
        currentDocument(taskID: expected.taskID) == expected
    }

    func navigate(taskID: String, operationID: String, to url: URL,
                  from expectedDocument: ComputerUseBrowserDocument? = nil,
                  requiringUnnavigatedSession expectedSession: ComputerUseBrowserHandbackRequirement? = nil,
                  willBeginEffect: () throws -> Void = {}) async throws -> ComputerUseBrowserDocument {
        try await performNavigation(taskID: taskID, operationID: operationID, to: url, from: expectedDocument,
            requiringUnnavigatedSession: expectedSession, willBeginEffect: willBeginEffect)
    }

    private func performNavigation(taskID: String, operationID: String, to url: URL,
                  from expectedDocument: ComputerUseBrowserDocument? = nil,
                  requiringUnnavigatedSession expectedSession: ComputerUseBrowserHandbackRequirement? = nil,
                  willBeginEffect: () throws -> Void = {}, historyTarget: ComputerUseBrowserNavigationTarget? = nil) async throws -> ComputerUseBrowserDocument {
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard !navigationAttemptIDs.contains(operationID), navigationAttemptIDs.count < 64,
              receipts[operationID] == nil, receipts.count < 64, !operationID.isEmpty else {
            // An uncertain navigation is reconciled by the step engine. This
            // adapter never reissues an attempted operation ID on its own.
            throw ComputerUseBrowserError.pageChanged
        }
        guard let url = Self.validatedURL(url) else { throw ComputerUseBrowserError.invalidURL }
        let capturedPolicy = sourcePolicy
        let historyItem = try historyTarget.flatMap { try self.historyItem(for: $0) }
        if let historyTarget, case .history = historyTarget.source, historyItem == nil {
            throw ComputerUseBrowserError.observedNavigationUnavailable
        }
        func checkSource() throws {
            try validateUnretiredNavigation(operationID: operationID)
            guard sourcePolicy == capturedPolicy else { throw ComputerUseBrowserError.pageChanged }
            try validateSourceURL(url)
            if let historyTarget {
                guard try self.historyItem(for: historyTarget) === historyItem else { throw ComputerUseBrowserError.pageChanged }
            }
        }
        try checkSource()
        if let expectedDocument, !validate(expectedDocument) { throw ComputerUseBrowserError.pageChanged }
        func checkInitialSession() throws {
            if let expectedSession {
                guard expectedSession.taskID == taskID, try isUnnavigatedSession(expectedSession) else {
                    throw ComputerUseBrowserError.pageChanged
                }
            }
        }
        try checkInitialSession()
        let browser = makeBrowser()
        presentIfNeeded(browser)
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
        // A later workflow step must still start from its exact prerequisite
        // document at dispatch. A historical receipt or equal URL is not a
        // current-document check. Keep this after presentation and before any
        // generation change, pending operation or WebKit load is created.
        if let expectedDocument {
            guard validate(expectedDocument) else { throw ComputerUseBrowserError.pageChanged }
            guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        }
        try checkInitialSession()
        try checkSource()
        try willBeginEffect()
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
        // Reacquiring the same task ID after a callback retires its earlier
        // document. Ownership alone cannot validate that prerequisite.
        if let expectedDocument {
            guard validate(expectedDocument) else { throw ComputerUseBrowserError.pageChanged }
            guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        }
        try checkInitialSession()
        try checkSource()
        guard !navigationAttemptIDs.contains(operationID), navigationAttemptIDs.count < 64 else { throw ComputerUseBrowserError.pageChanged }
        navigationAttemptIDs.insert(operationID)
        sessionHasNavigationActivity = true
        generation &+= 1
        let historySourceOperationID: String?
        if let historyTarget, case .history(let operationID) = historyTarget.source { historySourceOperationID = operationID }
        else { historySourceOperationID = nil }
        let sourceAttemptID = navigationDispatchLog?.begin(operationID: operationID, sessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, policy: capturedPolicy,
            requestedURL: url, historySourceOperationID: historySourceOperationID)
        document = nil
        loadedPageIdentity = nil
        retirePageObservations(.navigationStarted)
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        detail = "Opening page…"
        let id = UUID()
        return try await withTaskCancellationHandler {
            do {
                let result: ComputerUseBrowserDocument = try await withCheckedThrowingContinuation { continuation in
                    pending = PendingNavigation(id: id, taskID: taskID, generation: generation,
                        operationID: operationID, requestedURL: url, sourceAttemptID: sourceAttemptID, continuation: continuation)
                    pending?.historyOperationID = historySourceOperationID
                    pending?.timeout = Task { [weak self, navigationTimeout] in
                        do { try await Task.sleep(for: navigationTimeout) } catch { return }
                        self?.failPending(id: id, error: .deadlineExceeded)
                    }
                    if let historyItem { pending?.navigation = browser.go(to: historyItem) }
                    else { pending?.navigation = browser.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) }
                    if pending?.navigation == nil { failPending(id: id, error: .navigationFailed) }
                    if historyItem != nil, pending?.id == id {
                        // Cached/Instant Back may omit normal response/load
                        // callbacks. Confirm the exact retained native item,
                        // URL and settled state, then acquire fresh DOM identity.
                        pending?.restoration = Task { [weak self] in
                            while !Task.isCancelled, let self, self.pending?.id == id {
                                if self.finishHistoryRestoration(id: id) { return }
                                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                            }
                        }
                    }
                }
                let focusDeadline = ContinuousClock.now + .seconds(2)
                while !hasRequiredPresentation && ContinuousClock.now < focusDeadline {
                    try Task.checkCancellation()
                    guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try Task.checkCancellation()
                guard validate(result) else { throw ComputerUseBrowserError.ownershipLost }
                guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
                do {
                    loadedPageIdentity = try await readPageIdentity(validateContext: { self.validate(result) })
                } catch {
                    try Task.checkCancellation()
                    guard validate(result) else { throw ComputerUseBrowserError.pageChanged }
                    // Opening a PDF or other non-DOM resource does not depend
                    // on the text adapter. Such pages have no history proof.
                    loadedPageIdentity = nil
                }
                guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.failPending(id: id, error: .ownershipLost) }
        }
    }

    func stop() { stop(retirement: .stopped) }

    private func stop(retirement: NavigationHistory.ClaimEvent.Retirement) {
        closeSignInWindow(restoreParent: false)
        if let pending { failPending(id: pending.id, error: .ownershipLost) }
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.ownershipLost) }
        endObservedNavigation(.stopped)
        retirePageObservations(.stopped)
        if taskID != nil {
            navigationDispatchLog?.recordClaim(phase: .retired, parentSessionID: browser == nil ? nil : browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, retirement: retirement)
        }
        taskID = nil
        sourcePolicy = nil
        ownershipEpoch = UUID()
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        browser?.stopLoading()
        detail = "Stopped"
    }

    func close() {
        endObservedNavigation(.closed)
        retirePageObservations(.closed)
        stop(retirement: .closed)
        window?.delegate = nil
        window?.close()
        window?.contentView = nil
        window = nil
        releaseBrowser()
    }

    private func releaseBrowser() {
        closeSignInWindow(restoreParent: false)
        endObservedNavigation(.browserReleased)
        retirePageObservations(.browserReleased)
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.closed) }
        pendingDOM?.capture?.finish(.failure(ComputerUseBrowserError.closed))
        let waiters = pendingDOM?.completionWaiters ?? []
        pendingDOM = nil
        loadedPageIdentity = nil
        urlObservation = nil
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        browser = nil
        for waiter in waiters { waiter.resume() }
        displayedSite = ComputerUseBrowserSite.displayName(for: nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === signInWindow {
            closingWindow.delegate = nil
            closingWindow.contentView = nil
            signInWindow = nil
            closeSignInWindow()
            return
        }
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        if let controls = taskControls { requestTaskControl(.stop, displayed: controls) }
        stop(retirement: .closed)
        window?.contentView = nil
        window = nil
        releaseBrowser()
        detail = "Closed"
    }

    private func makeBrowser() -> WKWebView {
        if let browser { return browser }
        browserSessionID = UUID()
        if taskID != nil {
            navigationDispatchLog?.recordClaim(phase: .sessionCreated, parentSessionID: browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation)
        }
        sessionHasNavigationActivity = false
        locationRevision = 0
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Provider flows may open their window after an asynchronous response.
        // Our delegate admits one owned window only during explicit user control.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(WKUserScript(source: ComputerUseBrowserDOM.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ComputerUseBrowserDOM.world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] view, change in
            let url = change.newValue ?? nil
            if Thread.isMainThread {
                // Snapshot the gate at the URL event itself. Queuing this
                // until after Pause would misclassify an earlier AI-time
                // change, and could lose an A -> B -> A history transition.
                MainActor.assumeIsolated {
                    self?.locationChanged(in: view, to: url, ordered: true)
                }
            } else {
                Task { @MainActor [weak self, weak view] in
                    guard let view else { return }
                    // An unexpectedly unordered notification cannot confer
                    // handback authority. Invalidate using the current URL.
                    self?.locationChanged(in: view, to: view.url, ordered: false)
                }
            }
        }
        browser = view
        return view
    }

    private func locationChanged(in view: WKWebView, to url: URL?, ordered: Bool) {
        guard browser === view, view.url == url else { return }
        locationRevision &+= 1
        if url != nil || !ordered { sessionHasNavigationActivity = true }
        recordNavigationSlot(ordered ? .locationChanged : .unorderedLocationChange, url: url)
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        let changed = document.map { $0.committedURL != url } ?? false
        let observedChanged = (observedUserPage.map { $0.url != url } ?? false)
            || (observedActivePage.map { $0.url != url } ?? false)
        guard pending == nil, changed || observedChanged || !ordered else { return }
        let previousIdentity = loadedPageIdentity
        generation &+= 1
        document = nil
        retirePageObservations(.locationChanged)
        if ordered, let taskID, !view.isLoading, observedNavigation == nil,
           let previousIdentity, let url, Self.validatedURL(url) != nil {
            let source: ComputerUseBrowserDocument.Source = mayAct() ? .activePageObservation : .userControlObservation
            let evidence = NavigationHistory.PageObservation(taskID: taskID, parentSessionID: browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, url: url, basis: .sameDocumentCandidate,
                navigationCorrelationID: nil, source: source, requiresExplicitHandback: false)
            let observation = ObservedPage(evidence: evidence, url: url, proof: .sameDocument(previousIdentity))
            if source == .activePageObservation { observedActivePage = observation }
            else { observedUserPage = observation }
            recordPageObservation(.accepted, page: observation)
        } else {
            loadedPageIdentity = nil
        }
        detail = "Page changed"
    }

    private var isUserControllingTask: Bool {
        guard !mayAct(), let taskID, let controls = taskControls else { return false }
        return controls.taskID == taskID && controls.phase == .paused && controls.canResume
    }

    private var canOpenSignInWindow: Bool {
        isUserControllingTask && !hasOpenSignInWindow && pending == nil
            && pendingDOM == nil && browser?.isLoading == false
    }

    private var canNavigateSignInWindow: Bool {
        // An early Resume is rejected by reacquisition, but briefly publishes
        // a working phase. Keep the person's in-flight login alive during that
        // transition; the open child independently blocks all browser effects.
        guard hasOpenSignInWindow, let scope = signInScope else { return false }
        return taskID == scope.taskID && taskControls?.taskID == scope.taskID
            && taskControls?.ownerID == scope.ownerID
    }

    private static func isSignInLocation(_ url: URL?) -> Bool {
        guard let url else { return false }
        // An opener may allocate a blank window before obtaining the provider
        // URL. Other about/data/javascript/custom-scheme main pages are refused.
        return url.absoluteString == "about:blank" || validatedURL(url) != nil
    }

    private static func isSignInCreationLocation(_ url: URL?) -> Bool {
        // window.open() / window.open('') allocate a blank context with an
        // empty request URL. Only creation admits that omission; every later
        // child navigation still needs an explicit supported location.
        url == nil || url?.absoluteString.isEmpty == true || isSignInLocation(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === browser, navigationAction.targetFrame == nil,
              canOpenSignInWindow, Self.isSignInCreationLocation(navigationAction.request.url),
              let controls = taskControls else { return nil }
        // WebKit must supply the configuration and perform the initial load:
        // replacing either breaks opener/postMessage and the shared session.
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 720), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        signInScope = (controls.taskID, controls.ownerID)
        signInBrowser = child
        signInInstanceID = UUID()
        navigationDispatchLog?.recordControl(phase: .signInWindowOpened, parentSessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: navigationAction.request.url,
            handback: nil, workflowOperationID: nil, nativeOperationID: nil, signInWindowID: signInInstanceID)
        signInSite = ComputerUseBrowserSite.displayName(for: navigationAction.request.url)
        signInDetail = "You control this window. AI is paused."
        signInURLObservation = child.observe(\.url, options: [.new]) { [weak self] child, _ in
            Task { @MainActor [weak self, weak child] in
                guard let self, let child, signInBrowser === child else { return }
                signInSite = ComputerUseBrowserSite.displayName(for: child.url)
            }
        }
        if presentsWindow {
            let popup = NSWindow(contentRect: child.bounds, styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
            popup.title = "Sign-in window — AI Browser"
            popup.isReleasedWhenClosed = false
            popup.isRestorable = false
            popup.delegate = self
            popup.contentView = NSHostingView(rootView: OwnedBrowserSignInContent(context: self, browser: child))
            popup.minSize = NSSize(width: 480, height: 320)
            if let screen = window?.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                var frame = popup.frame
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                popup.setFrame(frame, display: false)
            }
            signInWindow = popup
            popup.makeKeyAndOrderFront(nil)
        }
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === signInBrowser else { return }
        closeSignInWindow()
    }

    func closeSignInWindow() { closeSignInWindow(restoreParent: true) }

    private func closeSignInWindow(restoreParent: Bool) {
        guard let child = signInBrowser else { return }
        let wasKey = signInWindow?.isKeyWindow == true
        navigationDispatchLog?.recordControl(phase: .signInWindowClosed, parentSessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: child.url,
            handback: nil, workflowOperationID: nil, nativeOperationID: nil, signInWindowID: signInInstanceID)
        // Retire delegate identity before stopping/closing: late child callbacks
        // can neither close a replacement nor change the main page's evidence.
        signInBrowser = nil
        signInInstanceID = nil
        signInScope = nil
        signInURLObservation = nil
        child.navigationDelegate = nil
        child.uiDelegate = nil
        child.stopLoading()
        signInWindow?.delegate = nil
        signInWindow?.close()
        signInWindow?.contentView = nil
        signInWindow = nil
        signInSite = nil
        detail = "Sign-in window closed — choose Let AI continue when you are ready"
        if restoreParent, wasKey { window?.makeKeyAndOrderFront(nil) }
        // Closing is not handback, a login assertion, or a navigation receipt.
    }

    private func presentIfNeeded(_ browser: WKWebView) {
        guard presentsWindow else { return }
        if window == nil {
            let window = NSWindow(contentRect: browser.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "AI Browser — Remote Desktop"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OwnedBrowserContent(context: self, browser: browser))
            window.minSize = NSSize(width: 480, height: 320)
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        // Opening this window is an explicit remote-user action. Cooperative
        // activation can be refused while another app is active, leaving no
        // key window for the following form request. Request activation here
        // and still verify actual foreground ownership before completion.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func failPending(id: UUID, error: ComputerUseBrowserError) {
        guard let pending, pending.id == id else { return }
        let outcome: ComputerUseBrowserNavigationDispatchHistory.Outcome
        switch error {
        case .sourceNotAllowed: outcome = .sourceBlocked
        case .ownershipLost: outcome = .ownershipLost
        case .deadlineExceeded: outcome = .timedOut
        default: outcome = .failed
        }
        navigationDispatchLog?.finish(pending.sourceAttemptID, outcome: outcome)
        self.pending = nil
        pending.timeout?.cancel()
        pending.restoration?.cancel()
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        detail = error.localizedDescription
        browser?.stopLoading()
        pending.continuation.resume(throwing: error)
    }

    private func recordNavigationObservation(_ phase: NavigationHistory.Phase, decision: NavigationHistory.Decision = .observed,
                                             url: URL?, binding: NavigationHistory.Binding, control: NavigationHistory.Control = .unknown,
                                             policyCheck: NavigationHistory.PolicyCheck = .notChecked,
                                             surface: NavigationHistory.Surface = .mainDocument,
                                             instantBack: Bool? = nil,
                                             attemptID: UUID? = nil, navigationCorrelationID: UUID? = nil) {
        navigationDispatchLog?.observe(phase: phase, decision: decision, binding: binding, control: control, surface: surface,
            policyCheck: policyCheck, configuredPolicy: surface == .mainDocument ? sourcePolicy : nil,
            url: url, attemptID: attemptID, navigationCorrelationID: navigationCorrelationID,
            parentSessionID: browserSessionID, ownershipEpoch: ownershipEpoch, generation: generation,
            signInWindowID: surface == .signInWindow ? signInInstanceID : nil, instantBack: instantBack)
    }

    private func recordPageObservation(_ phase: NavigationHistory.PageObservationEvent.Phase, page: ObservedPage,
                                       adoptedSource: ComputerUseBrowserDocument.Source? = nil, nativeReacquisitionID: UUID? = nil,
                                       retirement: NavigationHistory.PageObservationEvent.Retirement? = nil) {
        navigationDispatchLog?.recordPageObservation(phase: phase, observation: page.evidence,
            parentSessionID: browserSessionID, ownershipEpoch: ownershipEpoch, generation: generation,
            adoptedSource: adoptedSource, nativeReacquisitionID: nativeReacquisitionID, retirement: retirement)
    }

    private func retirePageObservations(_ reason: NavigationHistory.PageObservationEvent.Retirement) {
        if let page = observedUserPage {
            recordPageObservation(.retired, page: page, retirement: reason)
        }
        if let page = observedActivePage, page.id != observedUserPage?.id {
            recordPageObservation(.retired, page: page, retirement: reason)
        }
        observedUserPage = nil
        observedActivePage = nil
    }

    private func endObservedNavigation(_ reason: NavigationHistory.ObservedNavigationEnd) {
        guard let observed = observedNavigation else { return }
        if navigationDispatchLog?.taskID == observed.taskID {
            navigationDispatchLog?.observe(phase: .observedNavigationEnded, decision: .observed,
                binding: .exactObservedNavigation, control: .unknown, surface: .mainDocument,
                policyCheck: .notChecked, configuredPolicy: nil, url: nil, attemptID: nil,
                navigationCorrelationID: observed.id, parentSessionID: observed.parentSessionID,
                ownershipEpoch: observed.ownershipEpoch, generation: observed.generation,
                signInWindowID: nil, instantBack: nil, observedEnd: reason)
        }
        observedNavigation = nil
    }

    /// Legacy policy/URL callbacks do not supply a WKNavigation. Being in the
    /// pending slot is weaker than an exact native-object match. Recording an
    /// event does not add another control-gate query.
    private func recordNavigationSlot(_ phase: NavigationHistory.Phase, decision: NavigationHistory.Decision = .observed,
                                      url: URL?, control: NavigationHistory.Control = .unknown,
                                      policyCheck: NavigationHistory.PolicyCheck = .notChecked,
                                      surface: NavigationHistory.Surface = .mainDocument, exactHistoryItem: Bool = false, instantBack: Bool? = nil) {
        let pending = surface == .mainDocument ? self.pending : nil
        let observed = surface == .mainDocument ? observedNavigation : nil
        let binding: NavigationHistory.Binding = pending != nil ? (exactHistoryItem ? .exactHistoryItem : .pendingSlot)
            : (observed != nil ? .observedSlot : .none)
        recordNavigationObservation(phase, decision: decision, url: url, binding: binding, control: control,
            policyCheck: policyCheck, surface: surface, instantBack: instantBack, attemptID: pending?.sourceAttemptID,
            navigationCorrelationID: pending?.id ?? observed?.id)
    }

    private func recordNavigationCallback(_ phase: NavigationHistory.Phase, in view: WKWebView, navigation: WKNavigation?,
                                          control: NavigationHistory.Control = .unknown) {
        if view === signInBrowser {
            recordNavigationObservation(phase, url: view.url, binding: .none, control: control, surface: .signInWindow)
            return
        }
        guard view === browser else { return }
        if let navigation, let pending, navigation === pending.navigation {
            recordNavigationObservation(phase, url: view.url, binding: .exactPendingNavigation, control: control,
                attemptID: pending.sourceAttemptID, navigationCorrelationID: pending.id)
        } else if let navigation, let observed = observedNavigation, navigation === observed.navigation {
            recordNavigationObservation(phase, url: view.url, binding: .exactObservedNavigation, control: control,
                navigationCorrelationID: observed.id)
        } else {
            recordNavigationObservation(phase, url: view.url, binding: .none, control: control)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        func decide(_ decision: WKNavigationActionPolicy, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked) {
            if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil {
                if webView === browser || webView === signInBrowser {
                    recordNavigationSlot(navigationAction.targetFrame == nil ? .popupRequest : .navigationAction,
                        decision: decision == .allow ? .allowed : .cancelled, url: navigationAction.request.url,
                        control: control, policyCheck: policyCheck, surface: webView === browser ? .mainDocument : .signInWindow)
                }
            }
            decisionHandler(decision)
        }
        if webView === signInBrowser {
            guard canNavigateSignInWindow, let frame = navigationAction.targetFrame else {
                decide(.cancel)
                return
            }
            let permitted = frame.isMainFrame ? Self.isSignInLocation(navigationAction.request.url)
                : ["http", "https", "about", "data", "blob"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
            if !permitted { signInDetail = "This sign-in destination is not supported in the AI browser. Close this window to return." }
            decide(permitted ? .allow : .cancel, control: .userControl)
            return
        }
        guard webView === browser else { decide(.cancel); return }
        if !["GET", "HEAD"].contains((navigationAction.request.httpMethod ?? "").uppercased()) {
            pending?.readOnlyRequests = false
            if let pending, pending.historyOperationID != nil {
                decide(.cancel); failPending(id: pending.id, error: .navigationFailed); return
            }
        }
        // A popup cannot consume the main navigation's continuation. Admission
        // is rechecked when WebKit asks for the concrete child configuration.
        guard let frame = navigationAction.targetFrame else {
            let permitted = canOpenSignInWindow && Self.isSignInCreationLocation(navigationAction.request.url)
            decide(permitted ? .allow : .cancel, control: permitted ? .userControl : .unknown)
            return
        }
        guard frame.isMainFrame else {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            decide(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        sessionHasNavigationActivity = true
        guard let url = navigationAction.request.url, Self.validatedURL(url) != nil else {
            decide(.cancel)
            if let pending { failPending(id: pending.id, error: .invalidURL) }
            return
        }
        if let pending, !hasOwnership(taskID: pending.taskID) {
            decide(.cancel)
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(.cancel, control: .automationAllowed, policyCheck: .blocked)
            detail = "Blocked a page outside this task's allowed sources."
            if let pending { failPending(id: pending.id, error: .sourceNotAllowed) }
            return
        }
        decide(.allow, control: appliesPolicy ? .automationAllowed : .userControl,
            policyCheck: appliesPolicy ? (sourcePolicy == nil ? .unconfigured : .permitted) : .notChecked)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        func decide(_ decision: WKNavigationResponsePolicy, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked) {
            if navigationResponse.isForMainFrame, webView === browser || webView === signInBrowser {
                recordNavigationSlot(.response, decision: decision == .allow ? .allowed : .cancelled,
                    url: navigationResponse.response.url, control: control, policyCheck: policyCheck,
                    surface: webView === browser ? .mainDocument : .signInWindow)
            }
            decisionHandler(decision)
        }
        if webView === signInBrowser {
            guard canNavigateSignInWindow else { decide(.cancel); return }
            guard navigationResponse.isForMainFrame else { decide(.allow); return }
            // Error pages may explain a provider refusal to the person. They
            // are display only and never become task/navigation evidence.
            let permitted = navigationResponse.canShowMIMEType && Self.isSignInLocation(navigationResponse.response.url)
            if !permitted { signInDetail = "The sign-in page cannot be displayed. Close this window to return." }
            decide(permitted ? .allow : .cancel, control: .userControl)
            return
        }
        guard webView === browser else { decide(.cancel); return }
        guard navigationResponse.isForMainFrame else { decide(.allow); return }
        guard navigationResponse.canShowMIMEType,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let url = response.url, Self.validatedURL(url) != nil else {
            decide(.cancel)
            endObservedNavigation(.responseRejected)
            retirePageObservations(.responseRejected)
            if let pending { failPending(id: pending.id, error: .navigationFailed) }
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(.cancel, control: pending != nil ? .unknown : .automationAllowed, policyCheck: .blocked)
            detail = "Blocked a page outside this task's allowed sources."
            endObservedNavigation(.sourceBlocked)
            retirePageObservations(.sourceBlocked)
            if let pending { failPending(id: pending.id, error: .sourceNotAllowed) }
            return
        }
        pending?.successfulResponseURL = response.url
        observedNavigation?.successfulResponseURL = response.url
        decide(.allow, control: pending != nil ? .unknown : (appliesPolicy ? .automationAllowed : .userControl),
            policyCheck: appliesPolicy ? (sourcePolicy == nil ? .unconfigured : .permitted) : .notChecked)
    }

    /// Instant Back can restore a suspended page without the normal load
    /// callbacks. Apply the same task policy before allowing that restoration.
    @available(macOS 26.0, *)
    func webView(_ webView: WKWebView, shouldGoTo backForwardListItem: WKBackForwardListItem,
                 willUseInstantBack: Bool, completionHandler: @escaping (Bool) -> Void) {
        let url = backForwardListItem.url
        func decide(_ permitted: Bool, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked, exactHistoryItem: Bool = false) {
            if webView === browser || webView === signInBrowser {
                recordNavigationSlot(.historyRequest, decision: permitted ? .allowed : .cancelled, url: url,
                    control: control, policyCheck: policyCheck, surface: webView === browser ? .mainDocument : .signInWindow,
                    exactHistoryItem: exactHistoryItem, instantBack: willUseInstantBack)
            }
            completionHandler(permitted)
        }
        if webView === signInBrowser {
            let canNavigate = canNavigateSignInWindow
            decide(canNavigate && Self.isSignInLocation(url), control: canNavigate ? .userControl : .unknown)
            return
        }
        guard webView === browser, Self.validatedURL(url) != nil else { decide(false); return }
        if let pending, !hasOwnership(taskID: pending.taskID) {
            decide(false); failPending(id: pending.id, error: .ownershipLost)
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(false, control: .automationAllowed, policyCheck: .blocked)
            detail = "Blocked a page outside this task's allowed sources."
            if let pending { failPending(id: pending.id, error: .sourceNotAllowed) }
            return
        }
        var exactHistoryItem = false
        if let operationID = pending?.historyOperationID,
           let saved = historyReceipts[operationID], saved.item === backForwardListItem, saved.url == url {
            exactHistoryItem = true
            if willUseInstantBack { pending?.instantBackApproved = true }
        }
        decide(true, control: appliesPolicy ? .automationAllowed : .userControl,
            policyCheck: appliesPolicy ? (sourcePolicy == nil ? .unconfigured : .permitted) : .notChecked,
            exactHistoryItem: exactHistoryItem)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === signInBrowser {
            recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation)
            return
        }
        guard webView === browser else { return }
        sessionHasNavigationActivity = true
        locationRevision &+= 1
        guard let pending else {
            endObservedNavigation(.superseded)
            generation &+= 1
            document = nil
            loadedPageIdentity = nil
            retirePageObservations(.navigationStarted)
            if let navigation, let taskID {
                observedNavigation = ObservedNavigation(navigation: navigation, generation: generation,
                    taskID: taskID, parentSessionID: browserSessionID, ownershipEpoch: ownershipEpoch, startedWhileActive: mayAct())
            }
            recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation,
                control: observedNavigation.map { $0.startedWhileActive ? .automationAllowed : .userControl } ?? .unknown)
            detail = "Page changed"
            return
        }
        recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation)
        guard navigation === pending.navigation else { failPending(id: pending.id, error: .pageChanged); return }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // This callback supplies a WKNavigation, not a destination request.
        // The live WebView URL is a location observation, never a fabricated
        // redirect target or an allow/cancel policy decision.
        recordNavigationCallback(.serverRedirect, in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recordNavigationCallback(.documentCommitStarted, in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigationCallback(.documentFinished, in: webView, navigation: navigation)
        guard webView === browser else { return }
        if pending == nil {
            guard let observed = observedNavigation,
                  navigation === observed.navigation else { return }
            guard taskID == observed.taskID, observed.generation == generation,
                  let url = webView.url, Self.responseURL(observed.successfulResponseURL, matchesDocumentURL: url),
                  Self.validatedURL(url) != nil else { endObservedNavigation(.finishRejected); return }
            endObservedNavigation(.finished)
            let evidence = NavigationHistory.PageObservation(taskID: observed.taskID, parentSessionID: browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, url: url, basis: .completedNavigation,
                navigationCorrelationID: observed.id, source: observed.startedWhileActive ? .activePageObservation : .userControlObservation,
                requiresExplicitHandback: !mayAct())
            let page = ObservedPage(evidence: evidence, url: url, proof: .navigation)
            if observed.startedWhileActive { observedActivePage = page }
            else { observedUserPage = page }
            recordPageObservation(.accepted, page: page)
            displayedSite = ComputerUseBrowserSite.displayName(for: url)
            detail = observed.startedWhileActive && mayAct() ? "Page ready — checking the current task"
                : "Page ready — choose Let AI continue when you are finished"
            return
        }
        guard let pending, navigation === pending.navigation else { return }
        guard hasOwnership(taskID: pending.taskID), pending.generation == generation else {
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        // Retain exact current-history-item evidence even when WebKit also
        // delivered a response callback for the cached traversal. This reads
        // the existing predicate; admission still requires response OR item.
        let restoredHistory = isCurrentHistoryRestoration(pending)
        guard pending.receivedSuccessfulResponse || restoredHistory,
              let url = webView.url, Self.validatedURL(url) != nil else {
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        guard sourcePolicy?.permits(url) != false else {
            failPending(id: pending.id, error: .sourceNotAllowed)
            return
        }
        finishPendingNavigation(pending, url: url, basis: restoredHistory ? .historyItemAndFinish : .responseAndFinish)
    }

    private func isCurrentHistoryRestoration(_ pending: PendingNavigation) -> Bool {
        guard pending.readOnlyRequests, let id = pending.historyOperationID, let saved = historyReceipts[id],
              let browser, browser.backForwardList.currentItem === saved.item, saved.item.url == saved.url,
              browser.url == saved.url, pending.requestedURL == saved.url, !browser.isLoading else { return false }
        return true
    }

    private func finishHistoryRestoration(id: UUID) -> Bool {
        guard let pending, pending.id == id, pending.navigation != nil, pending.instantBackApproved,
              hasOwnership(taskID: pending.taskID), pending.generation == generation,
              isCurrentHistoryRestoration(pending), let url = browser?.url, sourcePolicy?.permits(url) != false else { return false }
        finishPendingNavigation(pending, url: url, basis: .instantBackHistoryItem)
        return true
    }

    private func finishPendingNavigation(_ pending: PendingNavigation, url: URL, basis: NavigationHistory.CommitBasis) {
        guard self.pending?.id == pending.id else { return }
        navigationDispatchLog?.finish(pending.sourceAttemptID, outcome: .documentCommitted, committedURL: url,
            commitBasis: basis, successfulResponseURL: pending.successfulResponseURL)
        let receipt = ComputerUseBrowserDocument(contextID: contextID, taskID: pending.taskID,
            generation: generation, operationID: pending.operationID, requestedURL: pending.requestedURL, committedURL: url)
        self.pending = nil
        pending.timeout?.cancel()
        pending.restoration?.cancel()
        document = receipt
        receipts[pending.operationID] = receipt
        if pending.readOnlyRequests, let item = browser?.backForwardList.currentItem, item.url == url {
            historyReceipts[pending.operationID] = .init(item: item, url: url, document: receipt)
        }
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        detail = "Page opened"
        pending.continuation.resume(returning: receipt)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationCallback(.navigationFailure, in: webView, navigation: navigation)
        if webView === signInBrowser {
            signInDetail = "The sign-in page did not finish loading. Close this window to return."
            return
        }
        guard webView === browser else { return }
        if let observed = observedNavigation, navigation === observed.navigation {
            endObservedNavigation(.callbackFailed)
            retirePageObservations(.navigationFailed)
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavigationCallback(.navigationFailure, in: webView, navigation: navigation)
        if webView === signInBrowser {
            signInDetail = "The sign-in page did not finish loading. Close this window to return."
            return
        }
        guard webView === browser else { return }
        if let observed = observedNavigation, navigation === observed.navigation {
            endObservedNavigation(.callbackFailed)
            retirePageObservations(.navigationFailed)
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recordNavigationCallback(.webContentTerminated, in: webView, navigation: nil)
        if webView === signInBrowser {
            closeSignInWindow()
            detail = "The sign-in window stopped. Check the main page before continuing."
            return
        }
        guard webView === browser else { return }
        closeSignInWindow(restoreParent: false)
        if let pending { failPending(id: pending.id, error: .navigationFailed) }
        endObservedNavigation(.processTerminated)
        retirePageObservations(.processTerminated)
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        detail = "Browser process stopped"
    }
}

private struct OwnedBrowserContent: View {
    @ObservedObject var context: ComputerUseOwnedBrowser
    let browser: WKWebView
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.displayedSite).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityLabel("Website: \(context.displayedSite)")
                    Text(context.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let controls = context.taskControls {
                    if controls.phase == .paused {
                        Button("Let AI continue") { context.requestTaskControl(.resume, displayed: controls) }
                            .disabled(!controls.canResume || context.hasOpenSignInWindow)
                    } else {
                        Button("Take control") { context.requestTaskControl(.takeControl, displayed: controls) }
                    }
                    Button("Stop AI") { context.requestTaskControl(.stop, displayed: controls) }
                }
            }.padding(12)
            if context.hasOpenSignInWindow {
                Text("Finish or close the sign-in window before returning control to AI.")
                    .font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            OwnedBrowserWebView(browser: browser)
        }.frame(minWidth: 480, minHeight: 320)
    }
}

private struct OwnedBrowserSignInContent: View {
    @ObservedObject var context: ComputerUseOwnedBrowser
    let browser: WKWebView
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(context.signInSite ?? "Website unavailable")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityLabel("Website: \(context.signInSite ?? "Website unavailable")")
                Text(context.signInDetail).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Close sign-in window") { context.closeSignInWindow() }
                    Spacer()
                    if let controls = context.taskControls {
                        Button("Stop AI") { context.requestTaskControl(.stop, displayed: controls) }
                    }
                }
            }.padding(12)
            Divider()
            OwnedBrowserWebView(browser: browser)
        }.frame(minWidth: 480, minHeight: 320)
    }
}

private struct OwnedBrowserWebView: NSViewRepresentable {
    let browser: WKWebView
    func makeNSView(context: Context) -> WKWebView { browser }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

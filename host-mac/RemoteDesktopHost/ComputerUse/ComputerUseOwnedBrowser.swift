import AppKit
import ImageIO
import Combine
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

    init(document: ComputerUseBrowserDocument, documentID: String, page: ComputerUseBrowserPageSnapshot) {
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
    let sessionID: UUID?
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

/// Cross-thread URL notification ingress. No WebKit/AppKit object or actor
/// callback is accessed under this lock. Delivery tickets never address a
/// later source/owner, including when an older scheduled task arrives last.
final class ComputerUseBrowserLocationInbox: @unchecked Sendable {
    struct Source: Equatable, Sendable { fileprivate let id = UUID() }
    struct Delivery: Equatable, Sendable {
        let source: Source
        let ownershipEpoch: UUID
        fileprivate let id = UUID()
    }
    struct Batch: Sendable {
        let delivery: Delivery
        let urls: [URL?]
        let overflowed: Bool
    }
    struct OwnerChange { let retired: Batch? }
    private let lock = NSLock()
    private var source: Source?
    private var ownershipEpoch = UUID()
    private var delivery: Delivery?
    private var urls: [URL?] = []
    private var overflowed = false

    var activeSource: Source? { lock.lock(); defer { lock.unlock() }; return source }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return delivery != nil }
    func isCurrent(_ expected: Delivery) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return delivery == expected
    }

    func beginSurface(ownershipEpoch: UUID) -> Source {
        lock.lock(); defer { lock.unlock() }
        let source = Source()
        self.source = source; self.ownershipEpoch = ownershipEpoch
        clearPending()
        return source
    }

    func endSurface() {
        lock.lock(); defer { lock.unlock() }
        source = nil
        clearPending()
    }

    func changeOwner(to epoch: UUID, requiringEmpty: Bool) -> OwnerChange? {
        lock.lock(); defer { lock.unlock() }
        guard !requiringEmpty || delivery == nil else { return nil }
        let retired = currentBatch()
        ownershipEpoch = epoch
        clearPending()
        return OwnerChange(retired: retired)
    }

    /// Only the first event needs a scheduled delivery. Later notifications
    /// join that exact ticket until it is consumed or its owner is retired.
    func enqueue(_ url: URL?, from source: Source) -> Delivery? {
        lock.lock(); defer { lock.unlock() }
        guard self.source == source else { return nil }
        if urls.count < 64 {
            if let url, url.absoluteString.utf8.count > 8_192 {
                urls.append(nil); overflowed = true
            } else { urls.append(url) }
        } else { overflowed = true }
        guard delivery == nil else { return nil }
        let next = Delivery(source: source, ownershipEpoch: ownershipEpoch)
        delivery = next
        return next
    }

    func take(_ expected: Delivery? = nil) -> Batch? {
        lock.lock(); defer { lock.unlock() }
        if let expected, delivery != expected { return nil }
        guard let result = currentBatch() else { return nil }
        clearPending()
        return result
    }

    private func currentBatch() -> Batch? {
        delivery.map { Batch(delivery: $0, urls: urls, overflowed: overflowed) }
    }

    private func clearPending() { delivery = nil; urls.removeAll(keepingCapacity: true); overflowed = false }
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
    /// A real snapshot of an allocated browser with no document or network
    /// activity. It grants only a first navigation, never page input authority.
    struct InitialAgentObservation: Equatable, Sendable {
        let png: Data
        fileprivate let session: ComputerUseBrowserHandbackRequirement
        fileprivate let id: UUID
        fileprivate let takeover: UUID
        fileprivate let viewportSize: NSSize
        fileprivate let windowFrame: NSRect
        var sessionIdentity: String { ComputerUseTaskContract.digest([session.contextID ?? "", session.taskID, session.ownershipEpoch?.uuidString ?? ""]) }
        var authorityDigest: String { ComputerUseTaskContract.digest([sessionIdentity, id.uuidString]) }
    }

    func captureInitialAgentObservation(taskID: String, expectedSessionIdentity: String?) async throws -> InitialAgentObservation? {
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        agentObservationID = nil
        defer { agentOperationInProgress = false }
        try Task.checkCancellation()
        let requirement: ComputerUseBrowserHandbackRequirement
        if let expectedSessionIdentity {
            guard let existing = handbackRequirement(taskID: taskID, required: true),
                  ComputerUseTaskContract.digest([existing.contextID ?? "", existing.taskID, existing.ownershipEpoch?.uuidString ?? ""]) == expectedSessionIdentity else {
                throw ComputerUseBrowserError.handbackContextLost
            }
            requirement = existing
        } else if self.taskID == taskID, let existing = handbackRequirement(taskID: taskID, required: true) {
            requirement = existing
        } else {
            requirement = try await admitResearchSession(taskID: taskID, assertAdmission: {})
        }
        try validateWorkflowSession(requirement)
        guard try isUnnavigatedSession(requirement) else { return nil }
        guard let view = browser else { throw ComputerUseBrowserError.closed }
        let takeover = takeoverEpoch
        presentIfNeeded(view)
        let deadline = ContinuousClock.now + .seconds(2)
        while !hasRequiredPresentation && ContinuousClock.now < deadline {
            try Task.checkCancellation(); try validateWorkflowSession(requirement)
            guard takeoverEpoch == takeover, try isUnnavigatedSession(requirement) else { throw ComputerUseBrowserError.pageChanged }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard hasRequiredPresentation, let window else { throw ComputerUseBrowserError.windowNotActive }
        // If this process already owns the key window, activation does not
        // suspend above. Realize the SwiftUI browser view before snapshotting
        // so a cold task cannot capture a still-detached WKWebView.
        window.contentView?.layoutSubtreeIfNeeded()
        guard view.window === window else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        let frame = window.frame, size = view.bounds.size
        guard size.width > 0, size.height > 0, window.backingScaleFactor > 0 else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        // WebKit has no document drawing area before its first load and its
        // snapshot API returns WKError(1). Capture this proven-empty native
        // view through AppKit. Loaded pages never use this path.
        guard let nativeBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        view.cacheDisplay(in: view.bounds, to: nativeBitmap)
        guard let raw = nativeBitmap.representation(using: .png, properties: [:]),
              let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1188] as CFDictionary) else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        try Task.checkCancellation(); try validateHandback(requirement, taskID: taskID)
        guard self.browser === view, self.window === window, takeoverEpoch == takeover,
              window.frame == frame, view.bounds.size == size, try isUnnavigatedSession(requirement),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ComputerUseBrowserError.pageChanged }
        try ComputerUseFaraModel.validatePNG(png)
        let id = UUID(); agentObservationID = id
        return InitialAgentObservation(png: png, session: requirement, id: id, takeover: takeover, viewportSize: size, windowFrame: frame)
    }

    func validateInitialAgentObservation(_ observation: InitialAgentObservation) throws {
        try Task.checkCancellation()
        try validateHandback(observation.session, taskID: observation.session.taskID)
        guard agentObservationID == observation.id, takeoverEpoch == observation.takeover,
              browser?.bounds.size == observation.viewportSize, window?.frame == observation.windowFrame,
              try isUnnavigatedSession(observation.session) else { throw ComputerUseBrowserError.pageChanged }
    }

    func performInitialAgentNavigation(_ url: URL, observation: InitialAgentObservation,
        operationID: String, willBeginEffect: () throws -> Void) async throws {
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        defer { agentOperationInProgress = false }
        try validateInitialAgentObservation(observation)
        _ = try await navigate(taskID: observation.session.taskID, operationID: operationID, to: url,
            requiringUnnavigatedSession: observation.session, willBeginEffect: {
                try self.validateInitialAgentObservation(observation)
                try willBeginEffect()
                self.agentObservationID = nil
            })
    }

    struct AgentObservation: Equatable, Sendable {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let viewportSize: NSSize
        fileprivate let id: UUID
        fileprivate let evidence: ComputerUseBrowserPageEvidence
        fileprivate let ownership: UUID
        fileprivate let takeover: UUID
        fileprivate let windowFrame: NSRect
        var sessionIdentity: String { ComputerUseTaskContract.digest([evidence.document.contextID, evidence.document.taskID, ownership.uuidString]) }
        fileprivate let findState: OwnedBrowserFindBar.State?
        var authorityDigest: String { ComputerUseTaskContract.digest([sessionIdentity, id.uuidString]) }
        var currentURL: URL { evidence.document.committedURL }
        var approvalPageEvidence: ComputerUseBrowserPageEvidence { evidence }
    }
    /// Created only from a current isolated-world target read. This is host
    /// evidence, never model output or a serialized controller payload.
    struct AgentTarget: Equatable, Sendable {
        enum Navigation: String, Sendable { case document, fragment }
        enum FindAction: String, Sendable { case show, queryClick, type, selectAll, next, previous, hide }
        fileprivate let observation: AgentObservation
        fileprivate let proposal: ComputerUseFaraAction
        let action: ComputerUsePredictedAction
        let context: String
        let isSearchSubmission: Bool
        let navigation: Navigation?
        let findAction: FindAction?
        fileprivate let elementID: String
        var pageEvidence: ComputerUseBrowserPageEvidence { observation.evidence }
        var fingerprint: ComputerUseApprovalFingerprint {
            .init(action: action, applicationID: "owned-browser:\(observation.sessionIdentity)",
                accessibilityIdentity: ComputerUseTaskContract.digest([observation.authorityDigest, elementID, context, String(isSearchSubmission), navigation?.rawValue ?? "activation", findAction?.rawValue ?? "page"]), visualDigest: nil)
        }
    }
    private var agentObservationID: UUID?
    private var agentOperationInProgress = false
    private var agentPointer = ComputerUseFaraAction.Point(x: 500, y: 500)
    private(set) var lastAgentTargetStatus: String?
    private(set) var lastAgentCaptureStage: String?

    /// Refreshing a stale scene must retain its task and user-control authority.
    /// This deliberately ignores document/layout changes, which the new capture verifies.
    func validateAgentSession(_ observation: AgentObservation) throws {
        try Task.checkCancellation()
        guard taskID == observation.evidence.document.taskID,
              contextID == observation.evidence.document.contextID,
              ownershipEpoch == observation.ownership, takeoverEpoch == observation.takeover,
              browser != nil, hasOwnership(taskID: observation.evidence.document.taskID) else {
            throw ComputerUseBrowserError.ownershipLost
        }
    }

    func validateAgentObservation(_ observation: AgentObservation) async throws {
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        defer { agentOperationInProgress = false }
        func check() throws {
            try Task.checkCancellation()
            guard agentObservationID == observation.id, validate(observation.evidence.document),
                  ownershipEpoch == observation.ownership, takeoverEpoch == observation.takeover,
                  browser?.bounds.size == observation.viewportSize, window?.frame == observation.windowFrame,
                  mainSurface?.findBar.state == observation.findState,
                  hasRequiredPresentation else { throw ComputerUseBrowserError.pageChanged }
        }
        try check()
        try await validatePageEvidence(observation.evidence)
        try check()
    }

    func captureAgentObservation(document expected: ComputerUseBrowserDocument) async throws -> AgentObservation {
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        agentObservationID = nil
        defer { agentOperationInProgress = false }
        lastAgentCaptureStage = "native-admission"
        try Task.checkCancellation()
        guard validate(expected), let view = browser, let window, hasRequiredPresentation else {
            throw ComputerUseBrowserError.pageChanged
        }
        let ownership = ownershipEpoch, takeover = takeoverEpoch
        let frame = window.frame, size = view.bounds.size
        let findState = mainSurface?.findBar.state
        guard size.width > 0, size.height > 0, window.backingScaleFactor > 0 else {
            throw ComputerUseBrowserError.pageEvidenceUnavailable
        }
        // Existing page admission detects credentials before screenshotting.
        // The host retains DOM evidence; the model receives the image and current URL.
        lastAgentCaptureStage = "observe-page"
        let evidence = try await observePage(document: expected, forAgentInput: true)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        let scale = min(1, 1188 / max(size.width, size.height))
        configuration.snapshotWidth = NSNumber(value: size.width * scale / window.backingScaleFactor)
        lastAgentCaptureStage = "snapshot-image"
        var image = try await view.takeSnapshot(configuration: configuration)
        if let surface = mainSurface, !surface.findBar.isHidden {
            image = try surface.snapshotIncludingFindBar(webImage: image)
        }
        lastAgentCaptureStage = "validate-page"
        try await validatePageEvidence(evidence)
        lastAgentCaptureStage = "validate-native"
        try Task.checkCancellation()
        guard validate(expected), self.browser === view, self.window === window,
              ownershipEpoch == ownership, takeoverEpoch == takeover,
              window.frame == frame, view.bounds.size == size, hasRequiredPresentation,
              mainSurface?.findBar.state == findState,
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ComputerUseBrowserError.pageChanged
        }
        try ComputerUseFaraModel.validatePNG(png)
        let id = UUID()
        agentObservationID = id
        lastAgentCaptureStage = "complete"
        return AgentObservation(png: png, pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh,
            viewportSize: size, id: id, evidence: evidence, ownership: ownership, takeover: takeover, windowFrame: frame, findState: findState)
    }

    /// Native and approval paths share the same integral screen point. The
    /// approval fingerprint must identify precisely where the click is posted.
    private func agentClickTarget(_ point: ComputerUseFaraAction.Point, observation: AgentObservation,
                                  view: WKWebView, window: NSWindow, count: Int = 1) throws -> (location: NSPoint, action: ComputerUsePredictedAction) {
        let pixel = try point.pixel(width: observation.pixelWidth, height: observation.pixelHeight)
        let x = CGFloat(pixel.x) / CGFloat(observation.pixelWidth) * view.bounds.width
        let y = CGFloat(pixel.y) / CGFloat(observation.pixelHeight) * view.bounds.height
        let local = NSPoint(x: view.bounds.minX + x, y: view.isFlipped ? view.bounds.minY + y : view.bounds.maxY - y)
        let screen = window.convertPoint(toScreen: view.convert(local, to: nil))
        let primaryTop = CGDisplayBounds(CGMainDisplayID()).height
        let globalX = Int(floor(screen.x)), globalY = Int(floor(primaryTop - screen.y))
        let location = window.convertPoint(fromScreen: NSPoint(x: CGFloat(globalX), y: primaryTop - CGFloat(globalY)))
        guard view.bounds.contains(view.convert(location, from: nil)) else { throw ComputerUseBrowserError.pageChanged }
        return (location, .click(x: globalX, y: globalY, button: 0, count: count))
    }

    private static func agentKeyStroke(_ keys: [String]) -> (usage: Int, keyCode: UInt16, text: String, shift: Bool)? {
        switch keys.map({ $0.uppercased() }) {
        case ["ENTER"], ["RETURN"]: return (0x28, 36, "\r", false)
        case ["TAB"]: return (0x2B, 48, "\t", false)
        case ["SHIFT", "TAB"]: return (0x2B, 48, "\t", true)
        default: return nil
        }
    }

    private func findAction(_ action: ComputerUseFaraAction, observation: AgentObservation) throws -> AgentTarget.FindAction? {
        guard let surface = mainSurface else { return nil }
        let bar = surface.findBar
        if case .key(let raw) = action {
            let keys = raw.map { $0.uppercased() }
            let command = keys.count == 2 && ["CTRL", "CONTROL", "CMD", "COMMAND", "META"].contains(keys[0])
            if command && keys[1] == "F" {
                guard (window?.firstResponder as? any NSTextInputClient)?.hasMarkedText() != true else { throw ComputerUseBrowserError.pageChanged }
                return .show
            }
            if !bar.isHidden {
                if keys == ["ESC"] || keys == ["ESCAPE"] { return .hide }
                if command && keys[1] == "G" { return .next }
                if keys.count == 3, ["CTRL", "CONTROL", "CMD", "COMMAND", "META"].contains(keys[0]), keys[1] == "SHIFT", keys[2] == "G" { return .previous }
                if bar.editor != nil {
                    guard bar.editor?.hasMarkedText() == false else { throw ComputerUseBrowserError.pageChanged }
                    if command && keys[1] == "A" { return .selectAll }
                    if keys == ["ENTER"] || keys == ["RETURN"] { return .next }
                    if keys == ["SHIFT", "ENTER"] || keys == ["SHIFT", "RETURN"] { return .previous }
                    throw ComputerUseBrowserError.unsupportedDocument
                }
            }
        }
        guard !bar.isHidden else { return nil }
        if case .typeText(let text) = action, bar.editor != nil {
            guard text.utf8.count <= 32_768, bar.editor?.hasMarkedText() == false else { throw ComputerUseBrowserError.pageChanged }
            return .type
        }
        if case .pointer(.leftClick, let point) = action, let view = browser, let window {
            let location = try agentClickTarget(point, observation: observation, view: view, window: window).location
            let local = bar.convert(location, from: nil)
            if bar.bounds.contains(local) {
                if bar.query.frame.contains(local) { return .queryClick }
                if bar.next.frame.contains(local) { return .next }
                if bar.previous.frame.contains(local) { return .previous }
                if bar.done.frame.contains(local) { return .hide }
                throw ComputerUseBrowserError.unsupportedDocument
            }
        }
        return nil
    }

    func predictedAgentAction(_ action: ComputerUseFaraAction, observation: AgentObservation) throws -> ComputerUsePredictedAction? {
        try validateSourceDocument(observation.evidence.document)
        guard agentObservationID == observation.id, validate(observation.evidence.document),
              ownershipEpoch == observation.ownership, takeoverEpoch == observation.takeover,
              browser?.bounds.size == observation.viewportSize, window?.frame == observation.windowFrame,
              mainSurface?.findBar.state == observation.findState,
              hasRequiredPresentation, let view = browser, let window else { throw ComputerUseBrowserError.pageChanged }
        if let command = try findAction(action, observation: observation) {
            if case .pointer(.leftClick, let point) = action { return try agentClickTarget(point, observation: observation, view: view, window: window).action }
            switch command {
            case .show: return .key(usage: 0x09, modifiers: 1 << 3)
            case .type: if case .typeText(let text) = action { return .typeText(text) }
            case .selectAll: return .key(usage: 0x04, modifiers: 1 << 3)
            case .next, .previous: return .key(usage: 0x28, modifiers: command == .previous ? 1 << 1 : 0)
            case .hide: return .key(usage: 0x29, modifiers: 0)
            case .queryClick: break
            }
        }
        switch action {
        case .pointer(.leftClick, let point): return try agentClickTarget(point, observation: observation, view: view, window: window).action
        case .pointer(.doubleClick, let point): return try agentClickTarget(point, observation: observation, view: view, window: window, count: 2).action
        case .typeText(let text): return .typeText(text)
        case .key(let keys) where Self.agentKeyStroke(keys) != nil:
            let key = Self.agentKeyStroke(keys)!
            return .key(usage: key.usage, modifiers: key.shift ? 1 << 1 : 0)
        case .key(let keys) where keys.count == 2 && ["CTRL", "CONTROL", "CMD", "COMMAND", "META"].contains(keys[0].uppercased()) && keys[1].uppercased() == "A":
            return .key(usage: 0x04, modifiers: 1 << 3)
        default: return nil
        }
    }

    func inspectAgentTarget(_ action: ComputerUseFaraAction, observation: AgentObservation) async throws -> AgentTarget? {
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        defer { agentOperationInProgress = false }
        return try await readAgentTarget(action, observation: observation)
    }

    private func readAgentTarget(_ action: ComputerUseFaraAction, observation: AgentObservation) async throws -> AgentTarget? {
        guard let predicted = try predictedAgentAction(action, observation: observation) else { return nil }
        guard let view = browser, let window else { throw ComputerUseBrowserError.pageChanged }
        if let command = try findAction(action, observation: observation) {
            // Browser chrome is native host UI. Its identity, exact query,
            // selection and focus are retained with the screenshot; it never
            // borrows a DOM field or forwards its keys to the document.
            try await validatePageEvidence(observation.evidence)
            guard try predictedAgentAction(action, observation: observation) == predicted else { throw ComputerUseBrowserError.pageChanged }
            return AgentTarget(observation: observation, proposal: action, action: predicted,
                context: "AXSearchField • Find in page search", isSearchSubmission: false,
                navigation: nil, findAction: command, elementID: "native-find-" + command.rawValue)
        }
        var arguments: [String: Any] = ["documentID": observation.evidence.documentID, "snapshotID": observation.evidence.page.id]
        switch action {
        case .pointer(.leftClick, let point), .pointer(.doubleClick, let point):
            guard let viewport = observation.evidence.page.viewport, viewport.isWellFormed else { throw ComputerUseBrowserError.pageChanged }
            let location = try agentClickTarget(point, observation: observation, view: view, window: window).location
            if let bar = mainSurface?.findBar, !bar.isHidden, bar.bounds.contains(bar.convert(location, from: nil)) {
                throw ComputerUseBrowserError.unsupportedDocument
            }
            let local = view.convert(location, from: nil)
            arguments["x"] = (local.x - view.bounds.minX) / view.bounds.width * viewport.width
            arguments["y"] = (view.isFlipped ? local.y - view.bounds.minY : view.bounds.maxY - local.y) / view.bounds.height * viewport.height
        case .typeText:
            arguments["focused"] = true
            arguments["editable"] = true
        case .key:
            arguments["focused"] = true
        default: return nil
        }
        let result = try await callDOM(.agentTarget, arguments: arguments, document: observation.evidence.document)
        lastAgentTargetStatus = result.status
        guard try predictedAgentAction(action, observation: observation) == predicted,
              result.status == "agent-target", result.documentID == observation.evidence.documentID,
              let id = result.agentTargetID, let context = result.agentTargetContext,
              id.utf8.count <= 65, context.utf8.count <= 8_192 else { throw ComputerUseBrowserError.pageChanged }
        let searchLabel = result.agentTargetSearchLabel
        guard searchLabel == nil || searchLabel!.utf8.count <= 256 else { throw ComputerUseBrowserError.pageChanged }
        let navigation = result.agentTargetNavigationKind.flatMap(AgentTarget.Navigation.init(rawValue:))
        if let kind = result.agentTargetNavigationKind {
            guard navigation != nil, navigation?.rawValue == kind, searchLabel == nil,
                  case .pointer(let kind, _) = action, kind == .leftClick || kind == .doubleClick,
                  observation.evidence.page.links.contains(where: { $0.id == id }) else { throw ComputerUseBrowserError.pageChanged }
        }
        // Opening a bound new-context URL or revealing a bound section is one
        // navigation even when Fara requests a double click. Never post a
        // second pointer event into a document changed by the first click.
        if case .pointer(.doubleClick, _) = action, navigation == nil { throw ComputerUseBrowserError.unsupportedDocument }
        return AgentTarget(observation: observation, proposal: action, action: predicted,
            context: context + (searchLabel.map { " • " + $0 } ?? ""),
            isSearchSubmission: searchLabel != nil, navigation: navigation, findAction: nil, elementID: id)
    }

    func validateAgentTarget(_ target: AgentTarget) async throws {
        guard try await inspectAgentTarget(target.proposal, observation: target.observation) == target else {
            throw ComputerUseBrowserError.pageChanged
        }
    }

    /// Delivers one already-admitted action to the owned native view. Returning
    /// means dispatch, not goal verification. The executor journals its attempt
    /// in willBeginEffect and observes the result before planning another action.
    func performAgentInput(_ action: ComputerUseFaraAction, observation: AgentObservation, operationID: String? = nil, target: AgentTarget? = nil,
                           willBeginEffect: () throws -> Void = {}) async throws {
        guard agentObservationID == observation.id else { throw ComputerUseBrowserError.pageChanged }
        guard !agentOperationInProgress else { throw ComputerUseBrowserError.busy }
        agentOperationInProgress = true
        defer {
            agentOperationInProgress = false
            if agentObservationID == observation.id { agentObservationID = nil }
        }
        func check() throws {
            try Task.checkCancellation()
            guard agentObservationID == observation.id, validate(observation.evidence.document),
                  ownershipEpoch == observation.ownership, takeoverEpoch == observation.takeover,
                  browser?.bounds.size == observation.viewportSize, window?.frame == observation.windowFrame,
                  mainSurface?.findBar.state == observation.findState,
                  hasRequiredPresentation else { throw ComputerUseBrowserError.pageChanged }
            try validateSourceDocument(observation.evidence.document)
        }
        try check()
        switch action {
        case .pointer(.leftClick, _), .pointer(.doubleClick, _), .typeText, .key:
            // The isolated target read below verifies the original control,
            // input geometry and authentication even when other content changes.
            break
        default: try await validatePageEvidence(observation.evidence)
        }
        try check()
        // Native input validates its point even when a caller does not supply
        // a retained approval target. Snapshot validation permits unrelated
        // animation; it is not input-location authority by itself.
        let inspectedTarget = try await readAgentTarget(action, observation: observation)
        try check()
        if let target {
            guard target.observation == observation, target.proposal == action,
                  inspectedTarget == target else { throw ComputerUseBrowserError.pageChanged }
            try check()
        }
        if let command = inspectedTarget?.findAction, let surface = mainSurface, let view = browser {
            try willBeginEffect(); try check()
            agentObservationID = nil
            switch command {
            case .show: surface.showFind()
            case .queryClick:
                guard case .pointer(.leftClick, let point) = action, let window else { throw ComputerUseBrowserError.pageChanged }
                let location = try agentClickTarget(point, observation: observation, view: view, window: window).location
                let time = ProcessInfo.processInfo.systemUptime
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                    timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                    timestamp: time + 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
                window.sendEvent(down); window.sendEvent(up)
            case .hide: surface.hideFind()
            case .selectAll:
                guard let editor = surface.findBar.editor, !editor.hasMarkedText() else { throw ComputerUseBrowserError.pageChanged }
                editor.selectAll(nil)
            case .type:
                guard case .typeText(let text) = action, text.utf8.count <= 32_768,
                      let editor = surface.findBar.editor, !editor.hasMarkedText() else { throw ComputerUseBrowserError.pageChanged }
                editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                try await surface.find(backwards: false)
            case .next, .previous: try await surface.find(backwards: command == .previous)
            }
            try Task.checkCancellation()
            guard self.mainSurface === surface, self.browser === view,
                  validate(observation.evidence.document), ownershipEpoch == observation.ownership,
                  takeoverEpoch == observation.takeover, hasRequiredPresentation else { throw ComputerUseBrowserError.pageChanged }
            return
        }
        let destination: URL?
        if case .visitURL(let url) = action { destination = url }
        else if inspectedTarget?.navigation == .document, let linkID = inspectedTarget?.elementID {
            guard let link = observation.evidence.page.links.first(where: { $0.id == linkID }),
                  let url = URL(string: link.destination).flatMap(Self.validatedURL) else { throw ComputerUseBrowserError.pageChanged }
            destination = url
        } else { destination = nil }
        if let url = destination {
            guard let operationID, !operationID.isEmpty else { throw ComputerUseBrowserError.unsupportedDocument }
            // Use the existing exact WKNavigation receipt path. Retire the
            // screenshot before load so it cannot authorize a second request.
            _ = try await navigate(taskID: observation.evidence.document.taskID, operationID: operationID,
                to: url, from: observation.evidence.document, willBeginEffect: {
                    try willBeginEffect()
                    try check()
                    if case .pointer(_, let point) = action { self.agentPointer = point }
                    self.agentObservationID = nil
                })
            return
        }
        if inspectedTarget?.navigation == .fragment, let linkID = inspectedTarget?.elementID {
            guard let operationID, !operationID.isEmpty else { throw ComputerUseBrowserError.unsupportedDocument }
            try willBeginEffect(); try check()
            if case .pointer(_, let point) = action { agentPointer = point }
            let result = try await callDOM(.agentFragmentScroll, arguments: [
                "documentID": observation.evidence.documentID, "snapshotID": observation.evidence.page.id,
                "operationID": operationID, "linkID": linkID], validateContext: { (try? check()) != nil })
            guard result.status == "agent-scroll-dispatched", result.documentID == observation.evidence.documentID else {
                throw ComputerUseBrowserError.viewportScrollUncertain
            }
            return
        }
        if case .historyBack = action {
            guard let operationID, let view = browser, let item = view.backForwardList.backItem else {
                throw ComputerUseBrowserError.observedNavigationUnavailable
            }
            // Bind the immediate native item, never a model-supplied URL or a
            // fresh load of a historical address. The shared traversal path
            // rejects non-read-only requests and enforces source/owner checks.
            let navigationTarget = try agentHistoryBackTarget(item: item, evidence: observation.evidence)
            _ = try await openObservedDestination(navigationTarget, operationID: operationID, willBeginEffect: {
                try check()
                guard view.backForwardList.backItem === item else { throw ComputerUseBrowserError.pageChanged }
                try willBeginEffect()
                try check()
                guard view.backForwardList.backItem === item else { throw ComputerUseBrowserError.pageChanged }
                self.agentObservationID = nil
            })
            return
        }
        guard let view = browser, let window else { throw ComputerUseBrowserError.closed }
        if case .scroll(let horizontal, let pixels) = action {
            guard pixels.isFinite, abs(pixels) <= 10_000,
                  let viewport = observation.evidence.page.viewport, viewport.isWellFormed else {
                throw ComputerUseBrowserError.viewportScrollUnavailable
            }
            let position = try agentClickTarget(agentPointer, observation: observation, view: view, window: window).location
            let local = view.convert(position, from: nil)
            try willBeginEffect()
            try check()
            // Fixed isolated-world scrolling shares the page's target validation.
            // A failed reply is uncertain; never send a wheel fallback or retry.
            let result = try await callDOM(.agentScroll, arguments: [
                "documentID": observation.evidence.documentID, "snapshotID": observation.evidence.page.id,
                "operationID": operationID ?? ComputerUseTaskContract.digest([observation.authorityDigest, "scroll"]),
                "x": (local.x - view.bounds.minX) / view.bounds.width * viewport.width,
                "y": (view.isFlipped ? local.y - view.bounds.minY : view.bounds.maxY - local.y) / view.bounds.height * viewport.height,
                "horizontal": horizontal, "pixels": pixels], validateContext: { (try? check()) != nil })
            guard result.status == "agent-scroll-dispatched", result.documentID == observation.evidence.documentID else {
                throw ComputerUseBrowserError.viewportScrollUncertain
            }
            return
        }
        let dispatch: () throws -> Void
        switch action {
        case .pointer(.leftClick, let point):
            let location = try agentClickTarget(point, observation: observation, view: view, window: window).location
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: time + 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else {
                throw ComputerUseBrowserError.pageEvidenceUnavailable
            }
            dispatch = {
                self.agentPointer = point
                window.sendEvent(down)
                // Release the same native button even if a callback revokes
                // control. No subsequent action may reuse this observation.
                window.sendEvent(up)
            }
        case .typeText(let text):
            guard text.utf8.count <= 32_768, let responder = window.firstResponder as? NSView,
                  responder === view || responder.isDescendant(of: view),
                  let client = responder as? any NSTextInputClient, !client.hasMarkedText() else {
                throw ComputerUseBrowserError.pageChanged
            }
            dispatch = {
                // Native insertion uses the current selection and generates
                // WebKit input events. It never adds select-all or Return.
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case .key(let keys) where Self.agentKeyStroke(keys) != nil:
            guard let key = Self.agentKeyStroke(keys), let responder = window.firstResponder as? NSView,
                  responder === view || responder.isDescendant(of: view),
                  let client = responder as? any NSTextInputClient, !client.hasMarkedText() else {
                throw ComputerUseBrowserError.pageChanged
            }
            let time = ProcessInfo.processInfo.systemUptime
            let flags: NSEvent.ModifierFlags = key.shift ? [.shift] : []
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time,
                windowNumber: window.windowNumber, context: nil, characters: key.text, charactersIgnoringModifiers: key.text, isARepeat: false, keyCode: key.keyCode),
                  let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: time + 0.001,
                windowNumber: window.windowNumber, context: nil, characters: key.text, charactersIgnoringModifiers: key.text, isARepeat: false, keyCode: key.keyCode) else {
                throw ComputerUseBrowserError.pageEvidenceUnavailable
            }
            // Preserve WebKit's key/form behavior. Admission and the durable
            // attempt happen before this one native down/up pair.
            dispatch = { window.sendEvent(down); window.sendEvent(up) }
        case .key(let keys) where keys.count == 2
            && ["CTRL", "CONTROL", "CMD", "COMMAND", "META"].contains(keys[0].uppercased())
            && keys[1].uppercased() == "A":
            guard let responder = window.firstResponder as? NSView,
                  responder === view || responder.isDescendant(of: view),
                  let client = responder as? any NSTextInputClient, !client.hasMarkedText() else {
                throw ComputerUseBrowserError.pageChanged
            }
            // Fara's browser select-all shortcut uses Control on its training
            // platform. Invoke the equivalent native editing command on macOS.
            dispatch = { client.doCommand(by: #selector(NSText.selectAll(_:))) }
        default:
            throw ComputerUseBrowserError.unsupportedDocument
        }
        try willBeginEffect()
        try check()
        agentObservationID = nil
        try dispatch()
    }

    private typealias NavigationHistory = ComputerUseBrowserNavigationDispatchHistory
    let contextID = UUID().uuidString
    private let presentation = ComputerUseBrowserPresentation()
    var objectWillChange: ObservableObjectPublisher { presentation.objectWillChange }
    private(set) var displayedSite: String {
        get { presentation.state.site }
        set { publish(.site(newValue)) }
    }
    var detail: String { presentation.state.detail }
    var taskDetail: String { hasOpenSignInWindow ? "You control sign-in. AI is waiting." : presentation.state.taskDetail }
    var pageDetail: String { presentation.state.page.displayDetail }
    var pageIssue: String? { presentation.state.issue?.message }
    var taskControls: ComputerUseBrowserTaskControls? { presentation.state.controls }
    private(set) var signInSite: String? {
        get { presentation.state.signInSite }
        set { publish(.signInSite(newValue), child: true) }
    }
    var signInDetail: String { presentation.state.signInDetail }
    var signInPageDetail: String? { presentation.state.signInStatus.activity.detail }
    var signInIssue: String? { presentation.state.signInStatus.warning?.message }
    var displayedSiteChanges: AnyPublisher<String, Never> { presentation.siteChanges }
    var detailChanges: AnyPublisher<String, Never> { presentation.detailChanges }
    var signInSiteChanges: AnyPublisher<String?, Never> { presentation.signInSiteChanges }
    var signInDetailChanges: AnyPublisher<String, Never> { presentation.signInDetailChanges }
    var taskControlsChanges: AnyPublisher<ComputerUseBrowserTaskControls?, Never> { presentation.controlsChanges }
    private var taskControlHandler: ComputerUseBrowserPresentation.Handler? { presentation.state.handler }
    private var controlUpdateID = UUID()
    private(set) var taskID: String?
    private var generation: UInt64 = 0
    private var ownershipEpoch = UUID()
    // Pause must invalidate a preparation even if admission reopens before
    // its synchronous callback returns. Handback keeps ownershipEpoch intact.
    private var takeoverEpoch = UUID()
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
    private let nativeNavigationDidDispatch: ((WKWebView, WKNavigation?) -> Void)?
    private var browser: WKWebView?
    private var window: NSWindow?
    private var mainSurface: OwnedBrowserSurface?
    // Remember identity while WebKit or a callback still retains the object.
    // Do not pin every past load or forget a live retired navigation by age.
    private let knownMainNavigations = NSHashTable<WKNavigation>(options: [.weakMemory, .objectPointerPersonality], capacity: 0)
    @MainActor
    private final class NativeNavigationDispatch {
        struct Callback {
            let navigation: WKNavigation?
            let replay: () -> Void
        }
        let view: WKWebView
        let pendingID: UUID
        var callbacks: [Callback] = []

        init(view: WKWebView, pendingID: UUID) { self.view = view; self.pendingID = pendingID }
    }
    private var nativeNavigationDispatch: NativeNavigationDispatch?
    let locationChanges = ComputerUseBrowserLocationInbox()
    private var processingLocationChanges = false
    private var hasPendingLocationChanges: Bool { processingLocationChanges || locationChanges.hasPending }
    @MainActor
    private final class DeferredLocationDelivery {
        weak var view: WKWebView?
        let delivery: ComputerUseBrowserLocationInbox.Delivery
        init(view: WKWebView, delivery: ComputerUseBrowserLocationInbox.Delivery) { self.view = view; self.delivery = delivery }
    }
    private var deferredLocationDelivery: DeferredLocationDelivery?
    @MainActor
    private final class NativeRetirement {
        let view: WKWebView?
        let window: NSWindow?
        var releasesBrowser: Bool
        var windowIsClosing = false
        var windowControlRequest: (() -> Void)?
        var released = false
        var status: ComputerUseBrowserPresentation.TaskState

        init(view: WKWebView?, window: NSWindow?, releasesBrowser: Bool, status: ComputerUseBrowserPresentation.TaskState) {
            self.view = view; self.window = window; self.releasesBrowser = releasesBrowser; self.status = status
        }
    }
    private var nativeRetirement: NativeRetirement?
    @MainActor
    private final class ProcessFailureCleanup {
        let parent: WKWebView
        let taskID: String?
        let sessionID: UUID
        let ownershipEpoch: UUID
        var parentFailed: Bool

        init(parent: WKWebView, taskID: String?, sessionID: UUID, ownershipEpoch: UUID, parentFailed: Bool) {
            self.parent = parent; self.taskID = taskID; self.sessionID = sessionID
            self.ownershipEpoch = ownershipEpoch; self.parentFailed = parentFailed
        }
    }
    private var processFailureCleanup: ProcessFailureCleanup?
    private var isNativeCleanupActive: Bool { nativeRetirement != nil || processFailureCleanup != nil }
    private var urlObservation: NSKeyValueObservation?
    private var pending: PendingNavigation?
    private var pendingDOM: PendingDOM?
    private var observedNavigation: ObservedNavigation?
    private var observedUserPage: ObservedPage?
    private var observedActivePage: ObservedPage?
    private var loadedPageIdentity: String?
    private var signInBrowser: WKWebView?
    private var signInInstanceID: UUID?
    private var signInNavigation: ComputerUseSignInNavigation<WKNavigation>?
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
        var receivedMatchingCommit = false
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
        var nativeDispatchStarted = false
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
         domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)? = nil,
         nativeNavigationDidDispatch: ((WKWebView, WKNavigation?) -> Void)? = nil, mayAct: @escaping () -> Bool) {
        self.presentsWindow = presentsWindow
        self.navigationTimeout = navigationTimeout
        self.domTimeout = domTimeout
        self.domScriptDidDispatch = domScriptDidDispatch
        self.nativeNavigationDidDispatch = nativeNavigationDidDispatch
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

    /// Scope display mutations independently from document/action evidence.
    /// Child lifetime deliberately excludes the parent's document generation
    /// and control phase: the opener may navigate while sign-in is in progress.
    private func publish(_ update: ComputerUseBrowserPresentation.Update, child: Bool = false) {
        let parent = browser, session = browserSessionID, epoch = ownershipEpoch, ownerTask = taskID
        let childView = signInBrowser, childID = signInInstanceID, controlOwner = taskControls?.ownerID
        let childNavigation = signInNavigation, childRevision = signInNavigation?.revision
        let retainsChildNavigation: Bool
        switch update { case .signInStatus: retainsChildNavigation = true; default: retainsChildNavigation = false }
        let pageGeneration = generation, revision = locationRevision, takeover = takeoverEpoch
        let lifecycle: Bool
        switch update { case .claim, .retire: lifecycle = true; default: lifecycle = false }
        presentation.update(update) { [weak self] in
            guard let self, ownershipEpoch == epoch, taskID == ownerTask else { return false }
            if lifecycle { return true }
            guard browser === parent, browserSessionID == session, taskControls?.ownerID == controlOwner else { return false }
            if child {
                return signInBrowser === childView && signInInstanceID == childID
                    && (!retainsChildNavigation || (signInNavigation === childNavigation && signInNavigation?.revision == childRevision))
            }
            return generation == pageGeneration && locationRevision == revision && takeoverEpoch == takeover
        }
    }

    func updateTaskControls(_ controls: ComputerUseBrowserTaskControls?,
        handler: @escaping (ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void) {
        let updateID = UUID(), epoch = ownershipEpoch
        controlUpdateID = updateID
        if let scope = signInScope,
           controls?.taskID != scope.taskID || controls?.ownerID != scope.ownerID {
            closeSignInWindow(restoreParent: false)
        }
        guard controlUpdateID == updateID, ownershipEpoch == epoch else { return }
        // The snapshot and handler are one binding. Reentrant cleanup or a
        // will-change subscriber can replace it only with a newer update.
        presentation.update(.controls(controls, handler)) { [weak self] in
            self?.controlUpdateID == updateID && self?.ownershipEpoch == epoch
        }
    }

    fileprivate func controls(in view: WKWebView) -> ComputerUseBrowserTaskControls? {
        guard view === browser || view === signInBrowser, let controls = taskControls,
              controls.taskID == taskID else { return nil }
        if view === signInBrowser, !canNavigateSignInWindow { return nil }
        return controls
    }

    fileprivate func isCurrentMainView(_ view: WKWebView) -> Bool { view === browser }
    fileprivate func isCurrentSignInView(_ view: WKWebView) -> Bool { view === signInBrowser }

    fileprivate func closeSignInWindow(in view: WKWebView) {
        guard view === signInBrowser else { return }
        closeSignInWindow()
    }

    func requestTaskControl(_ action: ComputerUseBrowserTaskControls.Action,
                            displayed controls: ComputerUseBrowserTaskControls) {
        // Pass the rendered snapshot unchanged. The host validates its run and
        // presentation identity; a stale view cannot select the current task.
        taskControlHandler?(controls, action)
    }

    func claim(taskID: String) throws {
        guard !isNativeCleanupActive, nativeNavigationDispatch == nil else { throw ComputerUseBrowserError.busy }
        guard !hasPendingLocationChanges else { throw ComputerUseBrowserError.busy }
        guard !hasOpenSignInWindow else { throw ComputerUseBrowserError.signInWindowOpen }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard mayAct(), !taskID.isEmpty else { throw ComputerUseBrowserError.ownershipLost }
        guard !hasPendingLocationChanges else { throw ComputerUseBrowserError.busy }
        if self.taskID != taskID {
            let nextEpoch = UUID()
            guard locationChanges.changeOwner(to: nextEpoch, requiringEmpty: true) != nil else { throw ComputerUseBrowserError.busy }
            retirePageObservations(.claimChanged)
            if self.taskID != nil {
                navigationDispatchLog?.recordClaim(phase: .retired, parentSessionID: browser == nil ? nil : browserSessionID,
                    ownershipEpoch: ownershipEpoch, generation: generation, retirement: .replaced)
            }
            if navigationDispatchLog?.taskID != taskID {
                navigationDispatchLog = .init(taskID: taskID, contextID: contextID,
                    beganAfterAnotherClaim: navigationDispatchLog != nil)
            }
            ownershipEpoch = nextEpoch
            agentPointer = .init(x: 500, y: 500)
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
            let claimGeneration = generation, claimRevision = locationRevision, claimTakeover = takeoverEpoch
            publish(.claim(taskID))
            guard hasOwnership(taskID: taskID), ownershipEpoch == nextEpoch, self.taskID == taskID,
                  generation == claimGeneration, locationRevision == claimRevision, takeoverEpoch == claimTakeover,
                  pending == nil, pendingDOM == nil, observedNavigation == nil else {
                throw ComputerUseBrowserError.ownershipLost
            }
        }
    }

    func hasOwnership(taskID: String) -> Bool {
        guard !isNativeCleanupActive, !hasPendingLocationChanges, self.taskID == taskID, !hasOpenSignInWindow else { return false }
        let epoch = ownershipEpoch
        guard mayAct() else { return false }
        return !isNativeCleanupActive && !hasPendingLocationChanges && self.taskID == taskID
            && ownershipEpoch == epoch && !hasOpenSignInWindow
    }

    var hasOpenSignInWindow: Bool { signInBrowser != nil }
    var hasSession: Bool { browser != nil }

    var isFrontmostWindow: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        return NSApp.keyWindow === window
    }

    /// Routing evidence only. A foreground sign-in child must stay in the
    /// browser's manual-control path instead of becoming a global AX form.
    var hasFrontmostOwnedWindow: Bool {
        if isFrontmostWindow { return true }
        guard let signInWindow, hasOpenSignInWindow, signInWindow.isVisible, !signInWindow.isMiniaturized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        return NSApp.keyWindow === signInWindow
    }

    var hasRequiredPresentation: Bool { !hasOpenSignInWindow && (!presentsWindow || isFrontmostWindow) }

    /// A new current-form request may acquire the already-open owned page.
    /// This creates an ownership token, never a new navigation receipt.
    func acquireCurrentDocument(taskID: String) throws -> ComputerUseBrowserDocument {
        guard !hasPendingLocationChanges, pending == nil, pendingDOM == nil else { throw ComputerUseBrowserError.busy }
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
    var isLoadingPage: Bool { hasPendingLocationChanges || browser?.isLoading == true || pending != nil || observedNavigation != nil }

    var hasPageAwaitingHandback: Bool {
        guard let observedUserPage else { return false }
        return isCurrentPageObservation(observedUserPage)
    }

    private func isCurrentPageObservation(_ page: ObservedPage) -> Bool {
        !hasPendingLocationChanges && page.generation == generation && pending == nil
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

    func matchesAgentSession(taskID: String, identity: String) -> Bool {
        browser != nil && self.taskID == taskID
            && ComputerUseTaskContract.digest([contextID, taskID, ownershipEpoch.uuidString]) == identity
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
            !Task.isCancelled && (try? assertAdmission()) != nil && mayAct() && !hasOpenSignInWindow && !hasPendingLocationChanges
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
        publish(.page(.checkingRequest, recovered: true))
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
        return !hasPendingLocationChanges && !sessionHasNavigationActivity && browser.url == nil && !browser.isLoading
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
        guard !hasPendingLocationChanges else { throw ComputerUseBrowserError.busy }
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
            publish(.page(.returnedEmpty, recovered: true))
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
        publish(.page(.returned, recovered: true))
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
        publish(.page(.checking, recovered: true))
    }

    func callDOM(_ command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                 document expected: ComputerUseBrowserDocument, retaining capture: ComputerUseBrowserDOMReadCapture? = nil) async throws -> ComputerUseBrowserDOMReply {
        try await callDOM(command, arguments: arguments, document: expected, retaining: capture, validateContext: { self.validate(expected) })
    }

    func observePage(document expected: ComputerUseBrowserDocument, includingControlState: Bool = false,
                     forAgentInput: Bool = false) async throws -> ComputerUseBrowserPageEvidence {
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        var arguments: [String: Any] = [:]
        if includingControlState { arguments["includeControlState"] = true }
        if forAgentInput {
            guard let view = browser, let window else { throw ComputerUseBrowserError.closed }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            let top = CGDisplayBounds(CGMainDisplayID()).height - frame.maxY
            arguments["agentInput"] = true
            arguments["agentRaster"] = ["width": view.bounds.width, "height": view.bounds.height,
                "columns": ceil(frame.maxX)-ceil(frame.minX), "rows": ceil(top+frame.height)-ceil(top),
                "offsetX": ceil(frame.minX)-frame.minX, "offsetY": ceil(top)-top]
        }
        let result = try await callDOM(.pageSnapshot, arguments: arguments, document: expected)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard result.status == "page-snapshot", result.fields == nil,
              let page = result.page, page.isWellFormed, page.controlStateObserved == includingControlState,
              page.scopedControlIDs.isEmpty else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        if expected.source != .automationNavigation, historyReceipts.count < 64,
           let item = browser?.backForwardList.currentItem, item.url == expected.committedURL {
            // Native link navigation is an observed page, not an action receipt.
            // Retain its exact history item only after the page read succeeds;
            // it remains absent from `receipts` and keeps its observed source.
            historyReceipts[expected.operationID] = .init(item: item, url: item.url, document: expected)
        }
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
        if lastAgentCaptureStage == "validate-page" { lastAgentCaptureStage = "validate-page-" + result.status }
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
        guard let browser, let saved = historyReceipts[operationID], saved.wasObserved,
              (receipts[operationID] == saved.document || saved.document.source != .automationNavigation),
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

    private func agentHistoryBackTarget(item: WKBackForwardListItem,
                                        evidence: ComputerUseBrowserPageEvidence) throws -> ComputerUseBrowserNavigationTarget {
        guard let entry = historyReceipts.filter({ $0.value.item === item && $0.value.url == item.url })
            .max(by: { $0.value.document.generation < $1.value.document.generation }) else {
            throw ComputerUseBrowserError.observedNavigationUnavailable
        }
        let option = try historyOption(visit: 0, operationID: entry.key, evidence: evidence)
        guard option.mode == .back else { throw ComputerUseBrowserError.observedNavigationUnavailable }
        return option.target
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
        guard nativeNavigationDispatch == nil, pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard !navigationAttemptIDs.contains(operationID), navigationAttemptIDs.count < 64,
              receipts[operationID] == nil, receipts.count < 64, !operationID.isEmpty else {
            // An uncertain navigation is reconciled by the step engine. This
            // adapter never reissues an attempted operation ID on its own.
            throw ComputerUseBrowserError.pageChanged
        }
        guard let url = Self.validatedURL(url) else { throw ComputerUseBrowserError.invalidURL }
        let claimEpoch = ownershipEpoch, admissionEpoch = takeoverEpoch, initialGeneration = generation
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
        let sessionID = browserSessionID
        func checkOwner() throws {
            try Task.checkCancellation()
            guard hasOwnership(taskID: taskID), self.browser === browser, browserSessionID == sessionID,
                  ownershipEpoch == claimEpoch, takeoverEpoch == admissionEpoch else {
                throw ComputerUseBrowserError.ownershipLost
            }
        }
        func checkPreparation() throws {
            try checkOwner()
            guard generation == initialGeneration else { throw ComputerUseBrowserError.pageChanged }
            guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
            if let expectedDocument {
                guard validate(expectedDocument) else { throw ComputerUseBrowserError.pageChanged }
                guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            }
            try checkInitialSession()
            try checkSource()
        }
        try checkOwner()
        presentIfNeeded(browser)
        try checkPreparation()
        try willBeginEffect()
        // Same task text, a reopened gate, or a replacement blank browser
        // cannot give this preparation a new native lifetime.
        try checkPreparation()
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
        let navigationGeneration = generation
        let id = UUID()
        func checkPendingAdmission() throws {
            try checkOwner()
            guard pending?.id == id, generation == navigationGeneration,
                  pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.pageChanged }
            guard sourcePolicy == capturedPolicy else { throw ComputerUseBrowserError.pageChanged }
            try validateUnretiredNavigation(operationID: operationID)
            try validateSourceURL(url)
            if expectedDocument != nil, !hasRequiredPresentation { throw ComputerUseBrowserError.windowNotActive }
        }
        return try await withTaskCancellationHandler {
            do {
                let result: ComputerUseBrowserDocument = try await withCheckedThrowingContinuation { continuation in
                    pending = PendingNavigation(id: id, taskID: taskID, generation: navigationGeneration,
                        operationID: operationID, requestedURL: url, sourceAttemptID: sourceAttemptID, continuation: continuation)
                    pending?.historyOperationID = historySourceOperationID
                    pending?.timeout = Task { [weak self, navigationTimeout] in
                        do { try await Task.sleep(for: navigationTimeout) } catch { return }
                        self?.failPending(id: id, error: .deadlineExceeded)
                    }
                    do {
                        // Register before observable publication. A synchronous
                        // Take Control/Stop can now retire this exact request.
                        try checkPendingAdmission()
                        displayedSite = ComputerUseBrowserSite.displayName(for: url)
                        try checkPendingAdmission()
                        publish(.page(.opening))
                        try checkPendingAdmission()
                    } catch {
                        failPending(id: id, error: (error as? ComputerUseBrowserError) ?? .ownershipLost)
                        return
                    }
                    let dispatch = NativeNavigationDispatch(view: browser, pendingID: id)
                    nativeNavigationDispatch = dispatch
                    pending?.nativeDispatchStarted = true
                    let navigation: WKNavigation?
                    if let historyItem { navigation = browser.go(to: historyItem) }
                    else { navigation = browser.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) }
                    // A fixture can exercise the same unbound-return interval
                    // as a synchronous native delegate callback. Production
                    // has no hook. Bind the return before replaying callbacks.
                    nativeNavigationDidDispatch?(browser, navigation)
                    finishNavigationDispatch(dispatch, navigation: navigation)
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
                    try checkOwner()
                    try await Task.sleep(for: .milliseconds(25))
                }
                try checkOwner()
                guard validate(result) else { throw ComputerUseBrowserError.ownershipLost }
                guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
                do {
                    let identity = try await readPageIdentity(validateContext: { self.validate(result) })
                    try checkOwner()
                    guard validate(result) else { throw ComputerUseBrowserError.pageChanged }
                    loadedPageIdentity = identity
                } catch {
                    try checkOwner()
                    guard validate(result) else { throw ComputerUseBrowserError.pageChanged }
                    // Opening a PDF or other non-DOM resource does not depend
                    // on the text adapter. Such pages have no history proof.
                    loadedPageIdentity = nil
                }
                try checkOwner()
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

    /// Synchronous host takeover preparation after action admission closes.
    /// Retire only explicit AI work; preserve the native session, provider
    /// window and navigation already being observed under user control.
    func prepareForUserControl(taskID: String) {
        guard self.taskID == taskID, !mayAct() else { return }
        takeoverEpoch = UUID()
        let view = browser, sessionID = browserSessionID, epoch = ownershipEpoch
        let domID = pendingDOM?.id
        if let pending { failPending(id: pending.id, error: .ownershipLost) }
        guard self.taskID == taskID, browser === view, browserSessionID == sessionID,
              ownershipEpoch == epoch, !mayAct() else { return }
        // A dispatched script cannot be recalled. Withdraw its result now,
        // keeping the native slot occupied until its callback actually joins.
        if let domID { interruptDOM(id: domID, error: ComputerUseBrowserError.ownershipLost) }
    }

    func stop() { retireBrowser(releasesBrowser: false) }

    func close() { retireBrowser(releasesBrowser: true) }

    private func retireBrowser(releasesBrowser: Bool, closingWindow: NSWindow? = nil,
                               windowControlRequest: (() -> Void)? = nil) {
        defer { resumeLocationDeliveryIfNeeded() }
        if let active = nativeRetirement {
            // Native callbacks can upgrade Stop to Close, but cannot start a
            // second cleanup or share its view with a new claim midway through.
            active.releasesBrowser = active.releasesBrowser || releasesBrowser
            if releasesBrowser { active.status = .closed }
            if closingWindow === active.window, closingWindow != nil {
                active.windowIsClosing = true; active.status = .closed
                if active.windowControlRequest == nil { active.windowControlRequest = windowControlRequest }
            }
            return
        }
        let retirement = NativeRetirement(view: browser, window: window, releasesBrowser: releasesBrowser,
            status: releasesBrowser ? .closed : .stopped)
        retirement.windowIsClosing = closingWindow != nil
        retirement.windowControlRequest = windowControlRequest
        nativeRetirement = retirement
        let nextEpoch = UUID()
        if let retired = locationChanges.changeOwner(to: nextEpoch, requiringEmpty: false)?.retired {
            recordUnorderedLocations(retired)
            sessionHasNavigationActivity = true
        }
        deferredLocationDelivery = nil

        // Record old lifetimes and detach their logical authority before any
        // native teardown, continuation resumption or observable publication.
        let child = detachSignInWindow()
        let failed = pending.flatMap { detachPendingFailure(id: $0.id, error: .ownershipLost) }
        defer { failed?.continuation.resume(throwing: ComputerUseBrowserError.ownershipLost) }
        endObservedNavigation(releasesBrowser ? .closed : .stopped)
        retirePageObservations(releasesBrowser ? .closed : .stopped)
        if taskID != nil {
            navigationDispatchLog?.recordClaim(phase: .retired, parentSessionID: browser == nil ? nil : browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, retirement: releasesBrowser ? .closed : .stopped)
        }
        taskID = nil
        sourcePolicy = nil
        ownershipEpoch = nextEpoch
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.ownershipLost) }

        if let child { finishSignInNativeCleanup(child) }
        retirement.view?.stopLoading()
        releaseRetiredBrowserIfRequested(retirement)
        let request = retirement.windowControlRequest
        retirement.windowControlRequest = nil
        request?()
        releaseRetiredBrowserIfRequested(retirement)

        nativeRetirement = nil
        // Commit retirement coherently after captured native cleanup. Nested
        // publications may claim a successor, but cannot restore this status.
        publish(.retire(retirement.status, clearSite: retirement.released))
    }

    private func releaseRetiredBrowserIfRequested(_ retirement: NativeRetirement) {
        guard nativeRetirement === retirement, retirement.releasesBrowser, !retirement.released else { return }
        retirement.released = true
        let dom = pendingDOM
        pendingDOM = nil
        browser = nil
        window = nil
        mainSurface = nil
        locationChanges.endSurface()
        deferredLocationDelivery = nil
        urlObservation = nil
        retirement.view?.navigationDelegate = nil
        retirement.view?.uiDelegate = nil
        retirement.window?.delegate = nil
        if !retirement.windowIsClosing { retirement.window?.close() }
        retirement.window?.contentView = nil
        dom?.capture?.finish(.failure(ComputerUseBrowserError.closed))
        for waiter in dom?.completionWaiters ?? [] { waiter.resume() }
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
              closingWindow === window || closingWindow === nativeRetirement?.window else { return }
        let controls = taskControls, handler = taskControlHandler
        retireBrowser(releasesBrowser: true, closingWindow: closingWindow, windowControlRequest: {
            if let controls { handler?(controls, .stop) }
        })
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
        let changes = locationChanges
        let source = changes.beginSurface(ownershipEpoch: ownershipEpoch)
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] view, change in
            let url = change.newValue ?? nil
            if Thread.isMainThread {
                // Snapshot the gate at the URL event itself. Queuing this
                // until after Pause would misclassify an earlier AI-time
                // change, and could lose an A -> B -> A history transition.
                MainActor.assumeIsolated {
                    self?.receiveOrderedLocationChange(in: view, to: url, source: source)
                }
            } else if let delivery = changes.enqueue(url, from: source) {
                Task { @MainActor [weak self, weak view] in
                    guard let view else { return }
                    self?.deliverLocationChanges(in: view, delivery: delivery)
                }
            }
        }
        browser = view
        resumeLocationDeliveryIfNeeded()
        return view
    }

    private func receiveOrderedLocationChange(in view: WKWebView, to url: URL?, source: ComputerUseBrowserLocationInbox.Source) {
        guard !isNativeCleanupActive, browser === view, locationChanges.activeSource == source else { return }
        // Preserve the reported URL even if another change has already won.
        // Mixed/deferred delivery cannot mint a same-document handback.
        if hasPendingLocationChanges || view.url != url {
            if let delivery = locationChanges.enqueue(url, from: source) {
                Task { @MainActor [weak self, weak view] in
                    guard let view else { return }
                    self?.deliverLocationChanges(in: view, delivery: delivery)
                }
            }
            return
        }
        locationChanged(in: view, to: url)
    }

    func deliverLocationChanges(in view: WKWebView, delivery: ComputerUseBrowserLocationInbox.Delivery) {
        guard locationChanges.isCurrent(delivery) else { return }
        guard browser === view else {
            // An observation can be registered before makeBrowser installs
            // its view. Resume that exact delivery after registration ends.
            if browser == nil { deferredLocationDelivery = .init(view: view, delivery: delivery) }
            return
        }
        if isNativeCleanupActive || processingLocationChanges {
            deferredLocationDelivery = .init(view: view, delivery: delivery)
            return
        }
        drainLocationChanges(in: view, delivery: delivery)
    }

    private func resumeLocationDeliveryIfNeeded() {
        guard !isNativeCleanupActive, !processingLocationChanges, let deferred = deferredLocationDelivery else { return }
        deferredLocationDelivery = nil
        guard let view = deferred.view else { return }
        Task { @MainActor [weak self, weak view] in
            guard let view else { return }
            self?.deliverLocationChanges(in: view, delivery: deferred.delivery)
        }
    }

    private func recordUnorderedLocations(_ batch: ComputerUseBrowserLocationInbox.Batch) {
        guard taskID != nil, batch.delivery.ownershipEpoch == ownershipEpoch else { return }
        if batch.overflowed { navigationDispatchLog?.observationsOverflowed = true }
        // The URL is the notification's captured value. Native navigation,
        // policy and control classification were unavailable at ingress.
        for url in batch.urls {
            navigationDispatchLog?.observe(phase: .unorderedLocationChange, decision: .observed, binding: .none,
                control: .unknown, surface: .mainDocument, policyCheck: .notChecked, configuredPolicy: nil,
                url: url, attemptID: nil, navigationCorrelationID: nil, parentSessionID: browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, signInWindowID: nil, instantBack: nil)
        }
    }

    private func drainLocationChanges(in view: WKWebView, delivery: ComputerUseBrowserLocationInbox.Delivery? = nil) {
        defer { resumeLocationDeliveryIfNeeded() }
        guard browser === view, !isNativeCleanupActive, !processingLocationChanges,
              let batch = locationChanges.take(delivery), batch.delivery.ownershipEpoch == ownershipEpoch else { return }
        processingLocationChanges = true
        recordUnorderedLocations(batch)
        sessionHasNavigationActivity = true
        locationRevision &+= UInt64(max(1, batch.urls.count + (batch.overflowed ? 1 : 0)))
        // An exact native load can still establish its eventual document at
        // finish. These notifications alone cannot preserve an idle document
        // or create a same-document observation, even if the URL returned to A.
        let invalidatedIdlePage = pending == nil && observedNavigation == nil
        if invalidatedIdlePage {
            generation &+= 1
            document = nil
            loadedPageIdentity = nil
            retirePageObservations(.locationChanged)
        }
        let currentURL = view.url
        processingLocationChanges = false
        let callback = navigationCallbackScope(in: view)
        guard isCurrentNavigationCallback(callback) else { return }
        displayedSite = ComputerUseBrowserSite.displayName(for: currentURL)
        guard isCurrentNavigationCallback(callback) else { return }
        if invalidatedIdlePage { publish(.page(.changed)) }
    }

    private func prepareNavigationCallback(in view: WKWebView) -> Bool {
        guard !isNativeCleanupActive, !processingLocationChanges, let parent = browser,
              view === parent || view === signInBrowser else { return false }
        let epoch = ownershipEpoch, task = taskID, childID = signInInstanceID
        drainLocationChanges(in: parent)
        return !isNativeCleanupActive && !processingLocationChanges && browser === parent
            && ownershipEpoch == epoch && taskID == task
            && (view === parent || (view === signInBrowser && signInInstanceID == childID))
    }

    private func locationChanged(in view: WKWebView, to url: URL?) {
        guard !isNativeCleanupActive else { return }
        guard browser === view, view.url == url else { return }
        locationRevision &+= 1
        if url != nil { sessionHasNavigationActivity = true }
        recordNavigationSlot(.locationChanged, url: url)
        let callback = navigationCallbackScope(in: view)
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        guard isCurrentNavigationCallback(callback) else { return }
        let changed = document.map { $0.committedURL != url } ?? false
        let observedChanged = (observedUserPage.map { $0.url != url } ?? false)
            || (observedActivePage.map { $0.url != url } ?? false)
        guard pending == nil, changed || observedChanged else { return }
        let previousIdentity = loadedPageIdentity
        generation &+= 1
        document = nil
        retirePageObservations(.locationChanged)
        if let taskID, !view.isLoading, observedNavigation == nil,
           let previousIdentity, let url, Self.validatedURL(url) != nil {
            let changedScope = navigationCallbackScope(in: view)
            let active = mayAct()
            guard isCurrentNavigationCallback(changedScope) else { return }
            let source: ComputerUseBrowserDocument.Source = active ? .activePageObservation : .userControlObservation
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
        publish(.page(.changed))
    }

    private var isUserControllingTask: Bool {
        guard !mayAct(), let taskID, let controls = taskControls else { return false }
        return controls.taskID == taskID && controls.phase == .paused && controls.canResume
    }

    private var canOpenSignInWindow: Bool {
        !isNativeCleanupActive && !hasPendingLocationChanges && nativeNavigationDispatch == nil && isUserControllingTask && !hasOpenSignInWindow && pending == nil
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

    private func publishSignInStatus() {
        guard let signInNavigation, canNavigateSignInWindow else { return }
        publish(.signInStatus(signInNavigation.status), child: true)
    }

    private func warnSignIn(_ warning: ComputerUseSignInPageStatus.Warning) {
        guard let signInNavigation, canNavigateSignInWindow else { return }
        signInNavigation.warn(warning)
        publishSignInStatus()
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
        let sessionID = browserSessionID, epoch = ownershipEpoch
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 720), configuration: configuration)
        guard browser === webView, browserSessionID == sessionID, ownershipEpoch == epoch,
              taskID == controls.taskID, taskControls?.ownerID == controls.ownerID, canOpenSignInWindow else { return nil }
        child.navigationDelegate = self
        child.uiDelegate = self
        signInScope = (controls.taskID, controls.ownerID)
        signInBrowser = child
        signInInstanceID = UUID()
        signInNavigation = ComputerUseSignInNavigation<WKNavigation>()
        navigationDispatchLog?.recordControl(phase: .signInWindowOpened, parentSessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: navigationAction.request.url,
            handback: nil, workflowOperationID: nil, nativeOperationID: nil, signInWindowID: signInInstanceID)
        let instanceID = signInInstanceID
        func retainsCreation() -> Bool {
            // The parent may navigate during login. Retain the child/session
            // owner, not a document generation or the parent's source policy.
            guard signInBrowser === child, signInInstanceID == instanceID,
                  browser === webView, browserSessionID == sessionID, ownershipEpoch == epoch,
                  taskID == controls.taskID, signInScope?.taskID == controls.taskID,
                  signInScope?.ownerID == controls.ownerID, canNavigateSignInWindow else {
                // Only this exact child can be retired by an abandoned setup.
                if signInBrowser === child { closeSignInWindow(restoreParent: false) }
                return false
            }
            return true
        }
        signInSite = ComputerUseBrowserSite.displayName(for: navigationAction.request.url)
        guard retainsCreation() else { return nil }
        publishSignInStatus()
        guard retainsCreation() else { return nil }
        let observation = child.observe(\.url, options: [.new]) { [weak self] child, _ in
            Task { @MainActor [weak self, weak child] in
                guard let self, let child, signInBrowser === child else { return }
                signInSite = ComputerUseBrowserSite.displayName(for: child.url)
            }
        }
        guard retainsCreation() else { return nil }
        signInURLObservation = observation
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
            guard retainsCreation() else {
                popup.delegate = nil
                popup.contentView = nil
                popup.close()
                return nil
            }
            signInWindow = popup
            popup.makeKeyAndOrderFront(nil)
            guard retainsCreation(), signInWindow === popup else { return nil }
        }
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === signInBrowser else { return }
        closeSignInWindow()
    }

    func closeSignInWindow() { closeSignInWindow(restoreParent: true) }

    private struct DetachedSignInWindow {
        let child: WKWebView
        let popup: NSWindow?
        let parentWindow: NSWindow?
        let wasKey: Bool
        let controlsOwner: UUID?
        let closedScope: NavigationCallbackScope?
    }

    private func detachSignInWindow() -> DetachedSignInWindow? {
        guard let child = signInBrowser else { return nil }
        let popup = signInWindow, parent = browser, parentWindow = window
        let controlsOwner = taskControls?.ownerID
        let wasKey = popup?.isKeyWindow == true
        navigationDispatchLog?.recordControl(phase: .signInWindowClosed, parentSessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, generation: generation, url: child.url,
            handback: nil, workflowOperationID: nil, nativeOperationID: nil, signInWindowID: signInInstanceID)
        // Retire delegate identity before stopping/closing: late child callbacks
        // can neither close a replacement nor change the main page's evidence.
        signInBrowser = nil
        signInInstanceID = nil
        signInNavigation = nil
        signInScope = nil
        signInURLObservation = nil
        signInWindow = nil
        let closed = parent.flatMap { navigationCallbackScope(in: $0) }
        return .init(child: child, popup: popup, parentWindow: parentWindow, wasKey: wasKey,
            controlsOwner: controlsOwner, closedScope: closed)
    }

    private func finishSignInNativeCleanup(_ detached: DetachedSignInWindow) {
        detached.child.navigationDelegate = nil
        detached.child.uiDelegate = nil
        detached.child.stopLoading()
        detached.popup?.delegate = nil
        detached.popup?.close()
        detached.popup?.contentView = nil
    }

    private func closeSignInWindow(restoreParent: Bool) {
        guard let detached = detachSignInWindow() else { return }
        func retainsParent() -> Bool {
            isCurrentNavigationCallback(detached.closedScope) && taskControls?.ownerID == detached.controlsOwner
        }
        finishSignInNativeCleanup(detached)
        guard retainsParent() else { return }
        signInSite = nil
        guard retainsParent() else { return }
        publish(.page(.signInClosed))
        guard retainsParent(), window === detached.parentWindow else { return }
        if restoreParent, detached.wasKey { detached.parentWindow?.makeKeyAndOrderFront(nil) }
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
            let surface = OwnedBrowserSurface(browser: browser)
            mainSurface = surface
            window.contentView = NSHostingView(rootView: OwnedBrowserContent(context: self, browser: browser, surface: surface))
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

    private func detachPendingFailure(id: UUID, error: ComputerUseBrowserError) -> PendingNavigation? {
        guard let pending, pending.id == id else { return nil }
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
        return pending
    }

    private func failPending(id: UUID, error: ComputerUseBrowserError) {
        let view = browser, epoch = ownershipEpoch
        guard let pending = detachPendingFailure(id: id, error: error) else { return }
        let retiredGeneration = generation
        // stopLoading affects the native view, not one WKNavigation. Finish
        // this call before publishing detail, which may admit a successor.
        if pending.nativeDispatchStarted { view?.stopLoading() }
        if browser === view, ownershipEpoch == epoch, generation == retiredGeneration,
           taskID == pending.taskID, self.pending == nil {
            if error == .ownershipLost { publish(.page(.interrupted)) }
            else { publish(.issue(.navigation(error))) }
        }
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
        mainSurface?.hideFind()
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
        guard !isNativeCleanupActive else { return }
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

    private func isRetiredNavigation(_ navigation: WKNavigation?, in view: WKWebView) -> Bool {
        if view === signInBrowser { return signInNavigation?.isRetired(navigation) == true }
        guard view === browser, let navigation, knownMainNavigations.contains(navigation) else { return false }
        return navigation !== pending?.navigation && navigation !== observedNavigation?.navigation
    }

    private func deferNavigationCallback(_ phase: NavigationHistory.Phase, in view: WKWebView,
                                         navigation: WKNavigation?, replay: @escaping () -> Void) -> Bool {
        guard prepareNavigationCallback(in: view) else { return true }
        guard !isNativeCleanupActive, let dispatch = nativeNavigationDispatch, dispatch.view === view else { return false }
        guard !isRetiredNavigation(navigation, in: view) else { return true }
        // Preserve notification order and its original binding. Replaying
        // state handling after load returns must not manufacture a later
        // callback or promote an unbound history entry to an exact receipt.
        recordNavigationCallback(phase, in: view, navigation: navigation)
        dispatch.callbacks.append(.init(navigation: navigation, replay: replay))
        return true
    }

    private func finishNavigationDispatch(_ dispatch: NativeNavigationDispatch, navigation: WKNavigation?) {
        if let navigation { knownMainNavigations.add(navigation) }
        let callbacks = dispatch.callbacks
        dispatch.callbacks.removeAll()
        if nativeNavigationDispatch === dispatch { nativeNavigationDispatch = nil }
        if pending?.id == dispatch.pendingID {
            pending?.navigation = navigation
            if navigation == nil { failPending(id: dispatch.pendingID, error: .navigationFailed) }
        }
        for callback in callbacks {
            guard pending?.id == dispatch.pendingID else {
                // An early policy decision, Stop or completion retired the
                // original reservation. These callbacks cannot start a new
                // observation in whichever claim now occupies the view.
                if let navigation = callback.navigation { knownMainNavigations.add(navigation) }
                continue
            }
            callback.replay()
        }
    }

    // A policy callback lacks an exact WKNavigation. This snapshot prevents
    // reentrant continuation into a successor; it does not invent correlation
    // for a late callback that was already stale when it entered the delegate.
    private struct NavigationCallbackScope {
        let view: WKWebView
        let parent: WKWebView
        let isSignIn: Bool
        let taskID: String?
        let sessionID: UUID
        let ownershipEpoch: UUID
        let takeoverEpoch: UUID
        let generation: UInt64
        let locationRevision: UInt64
        let pendingID: UUID?
        let observedID: UUID?
        let userPageID: UUID?
        let activePageID: UUID?
        let signInID: UUID?
        let signInOwnerID: UUID?
        let sourcePolicy: ComputerUseBrowserSourcePolicy?
    }

    private func navigationCallbackScope(in view: WKWebView) -> NavigationCallbackScope? {
        // Failure cleanup may retain its post-invalidation context here;
        // isCurrentNavigationCallback admits it only after cleanup returns.
        guard nativeRetirement == nil, let browser, view === browser || view === signInBrowser else { return nil }
        return .init(view: view, parent: browser, isSignIn: view === signInBrowser,
            taskID: taskID, sessionID: browserSessionID, ownershipEpoch: ownershipEpoch, takeoverEpoch: takeoverEpoch,
            generation: generation, locationRevision: locationRevision, pendingID: pending?.id,
            observedID: observedNavigation?.id, userPageID: observedUserPage?.id, activePageID: observedActivePage?.id,
            signInID: signInInstanceID, signInOwnerID: signInScope?.ownerID, sourcePolicy: sourcePolicy)
    }

    private func isCurrentNavigationCallback(_ scope: NavigationCallbackScope?) -> Bool {
        guard !isNativeCleanupActive, let scope else { return false }
        if scope.isSignIn {
            return browser === scope.parent && scope.view === signInBrowser && taskID == scope.taskID
                && browserSessionID == scope.sessionID && ownershipEpoch == scope.ownershipEpoch
                && signInInstanceID == scope.signInID && signInScope?.ownerID == scope.signInOwnerID
                && canNavigateSignInWindow
        }
        guard !hasPendingLocationChanges else { return false }
        return browser === scope.parent && scope.view === browser
            && taskID == scope.taskID && browserSessionID == scope.sessionID && ownershipEpoch == scope.ownershipEpoch
            && takeoverEpoch == scope.takeoverEpoch && generation == scope.generation && locationRevision == scope.locationRevision
            && pending?.id == scope.pendingID && observedNavigation?.id == scope.observedID
            && observedUserPage?.id == scope.userPageID && observedActivePage?.id == scope.activePageID
            && signInInstanceID == scope.signInID && sourcePolicy == scope.sourcePolicy
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard prepareNavigationCallback(in: webView) else { decisionHandler(.cancel); return }
        let callback = navigationCallbackScope(in: webView)
        func decide(_ decision: WKNavigationActionPolicy, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked) {
            let current = isCurrentNavigationCallback(callback)
            if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil {
                if current {
                    recordNavigationSlot(navigationAction.targetFrame == nil ? .popupRequest : .navigationAction,
                        decision: decision == .allow ? .allowed : .cancelled, url: navigationAction.request.url,
                        control: control, policyCheck: policyCheck, surface: webView === browser ? .mainDocument : .signInWindow)
                }
            }
            decisionHandler(current ? decision : .cancel)
        }
        if webView === signInBrowser {
            guard canNavigateSignInWindow, let frame = navigationAction.targetFrame else {
                decide(.cancel)
                return
            }
            let permitted = frame.isMainFrame ? Self.isSignInLocation(navigationAction.request.url)
                : ["http", "https", "about", "data", "blob"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
            if !permitted { warnSignIn(.unsupportedDestination) }
            decide(permitted ? .allow : .cancel, control: .userControl)
            return
        }
        guard webView === browser else { decide(.cancel); return }
        if !["GET", "HEAD"].contains((navigationAction.request.httpMethod ?? "").uppercased()) {
            pending?.readOnlyRequests = false
            if let pending, pending.historyOperationID != nil {
                decide(.cancel)
                guard isCurrentNavigationCallback(callback) else { return }
                failPending(id: pending.id, error: .navigationFailed)
                return
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
            guard isCurrentNavigationCallback(callback) else { return }
            if let id = callback?.pendingID { failPending(id: id, error: .invalidURL) }
            return
        }
        if let pending, !hasOwnership(taskID: pending.taskID) {
            decide(.cancel)
            guard isCurrentNavigationCallback(callback) else { return }
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(.cancel, control: .automationAllowed, policyCheck: .blocked)
            guard isCurrentNavigationCallback(callback) else { return }
            if let id = callback?.pendingID { failPending(id: id, error: .sourceNotAllowed) }
            else { publish(.issue(.sourceBlocked)) }
            return
        }
        decide(.allow, control: appliesPolicy ? .automationAllowed : .userControl,
            policyCheck: appliesPolicy ? (sourcePolicy == nil ? .unconfigured : .permitted) : .notChecked)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard prepareNavigationCallback(in: webView) else { decisionHandler(.cancel); return }
        let callback = navigationCallbackScope(in: webView)
        func decide(_ decision: WKNavigationResponsePolicy, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked) {
            let current = isCurrentNavigationCallback(callback)
            if navigationResponse.isForMainFrame, current {
                recordNavigationSlot(.response, decision: decision == .allow ? .allowed : .cancelled,
                    url: navigationResponse.response.url, control: control, policyCheck: policyCheck,
                    surface: webView === browser ? .mainDocument : .signInWindow)
            }
            decisionHandler(current ? decision : .cancel)
        }
        if webView === signInBrowser {
            guard canNavigateSignInWindow else { decide(.cancel); return }
            guard navigationResponse.isForMainFrame else { decide(.allow); return }
            // Error pages may explain a provider refusal to the person. They
            // are display only and never become task/navigation evidence.
            let permitted = navigationResponse.canShowMIMEType && Self.isSignInLocation(navigationResponse.response.url)
            if !permitted { warnSignIn(.unsupportedDocument) }
            else if let response = navigationResponse.response as? HTTPURLResponse, (400...599).contains(response.statusCode) {
                // Keep the provider's page available for the person. Its HTTP
                // error is a warning, never a sign-in or completion assertion.
                warnSignIn(.providerError(response.statusCode))
            }
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
            guard isCurrentNavigationCallback(callback) else { return }
            endObservedNavigation(.responseRejected)
            retirePageObservations(.responseRejected)
            if let id = callback?.pendingID { failPending(id: id, error: .navigationFailed) }
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(.cancel, control: pending != nil ? .unknown : .automationAllowed, policyCheck: .blocked)
            guard isCurrentNavigationCallback(callback) else { return }
            endObservedNavigation(.sourceBlocked)
            retirePageObservations(.sourceBlocked)
            if let id = callback?.pendingID { failPending(id: id, error: .sourceNotAllowed) }
            else { publish(.issue(.sourceBlocked)) }
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
        guard prepareNavigationCallback(in: webView) else { completionHandler(false); return }
        let callback = navigationCallbackScope(in: webView)
        let url = backForwardListItem.url
        func decide(_ permitted: Bool, control: NavigationHistory.Control = .unknown,
                    policyCheck: NavigationHistory.PolicyCheck = .notChecked, exactHistoryItem: Bool = false) {
            let current = isCurrentNavigationCallback(callback)
            if current {
                recordNavigationSlot(.historyRequest, decision: permitted ? .allowed : .cancelled, url: url,
                    control: control, policyCheck: policyCheck, surface: webView === browser ? .mainDocument : .signInWindow,
                    exactHistoryItem: exactHistoryItem, instantBack: willUseInstantBack)
            }
            completionHandler(current && permitted)
        }
        if webView === signInBrowser {
            let canNavigate = canNavigateSignInWindow
            decide(canNavigate && Self.isSignInLocation(url), control: canNavigate ? .userControl : .unknown)
            return
        }
        guard webView === browser, Self.validatedURL(url) != nil else { decide(false); return }
        if let pending, !hasOwnership(taskID: pending.taskID) {
            decide(false)
            guard isCurrentNavigationCallback(callback) else { return }
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        let appliesPolicy = pending != nil || mayAct()
        if appliesPolicy, sourcePolicy?.permits(url) == false {
            decide(false, control: .automationAllowed, policyCheck: .blocked)
            guard isCurrentNavigationCallback(callback) else { return }
            if let id = callback?.pendingID { failPending(id: id, error: .sourceNotAllowed) }
            else { publish(.issue(.sourceBlocked)) }
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
        if deferNavigationCallback(.provisionalStart, in: webView, navigation: navigation, replay: { [weak self] in
            self?.handleProvisionalStart(in: webView, navigation: navigation, recordCallback: false)
        }) { return }
        handleProvisionalStart(in: webView, navigation: navigation, recordCallback: true)
    }

    private func handleProvisionalStart(in webView: WKWebView, navigation: WKNavigation?, recordCallback: Bool) {
        guard prepareNavigationCallback(in: webView) else { return }
        if webView === signInBrowser {
            guard !isRetiredNavigation(navigation, in: webView), canNavigateSignInWindow else { return }
            if recordCallback { recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation) }
            if signInNavigation?.start(navigation) == true { publishSignInStatus() }
            return
        }
        guard webView === browser else { return }
        guard !isRetiredNavigation(navigation, in: webView) else { return }
        if let navigation, let observed = observedNavigation, navigation === observed.navigation {
            // A repeated start for the same live navigation is not a second
            // observed load and must not discard its response or handback ID.
            if recordCallback {
                recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation,
                    control: observed.startedWhileActive ? .automationAllowed : .userControl)
            }
            return
        }
        if let navigation { knownMainNavigations.add(navigation) }
        sessionHasNavigationActivity = true
        locationRevision &+= 1
        guard let pending else {
            endObservedNavigation(.superseded)
            generation &+= 1
            document = nil
            loadedPageIdentity = nil
            retirePageObservations(.navigationStarted)
            if let navigation, let taskID {
                let callback = navigationCallbackScope(in: webView)
                let startedWhileActive = mayAct()
                guard isCurrentNavigationCallback(callback) else { return }
                observedNavigation = ObservedNavigation(navigation: navigation, generation: generation,
                    taskID: taskID, parentSessionID: browserSessionID, ownershipEpoch: ownershipEpoch, startedWhileActive: startedWhileActive)
            }
            if recordCallback {
                recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation,
                    control: observedNavigation.map { $0.startedWhileActive ? .automationAllowed : .userControl } ?? .unknown)
            }
            publish(.page(.changed))
            return
        }
        if recordCallback { recordNavigationCallback(.provisionalStart, in: webView, navigation: navigation) }
        guard navigation === pending.navigation else { failPending(id: pending.id, error: .pageChanged); return }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if deferNavigationCallback(.serverRedirect, in: webView, navigation: navigation, replay: {}) { return }
        guard !isRetiredNavigation(navigation, in: webView) else { return }
        // This callback supplies a WKNavigation, not a destination request.
        // The live WebView URL is a location observation, never a fabricated
        // redirect target or an allow/cancel policy decision.
        recordNavigationCallback(.serverRedirect, in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let committedURL = webView.url
        if deferNavigationCallback(.documentCommitStarted, in: webView, navigation: navigation, replay: { [weak self] in
            self?.acceptObservedCommit(in: webView, navigation: navigation, url: committedURL)
        }) { return }
        guard !isRetiredNavigation(navigation, in: webView) else { return }
        recordNavigationCallback(.documentCommitStarted, in: webView, navigation: navigation)
        acceptObservedCommit(in: webView, navigation: navigation, url: committedURL)
    }

    private func acceptObservedCommit(in view: WKWebView, navigation: WKNavigation?, url: URL?) {
        guard !isNativeCleanupActive, view === browser, let observed = observedNavigation,
              navigation === observed.navigation, observed.generation == generation, taskID == observed.taskID,
              observed.ownershipEpoch == ownershipEpoch, let url,
              Self.responseURL(observed.successfulResponseURL, matchesDocumentURL: url) else { return }
        observedNavigation?.receivedMatchingCommit = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if deferNavigationCallback(.documentFinished, in: webView, navigation: navigation, replay: { [weak self] in
            self?.handleNavigationFinished(in: webView, navigation: navigation, recordCallback: false)
        }) { return }
        handleNavigationFinished(in: webView, navigation: navigation, recordCallback: true)
    }

    private func handleNavigationFinished(in webView: WKWebView, navigation: WKNavigation?, recordCallback: Bool) {
        guard prepareNavigationCallback(in: webView) else { return }
        guard !isRetiredNavigation(navigation, in: webView) else { return }
        if recordCallback { recordNavigationCallback(.documentFinished, in: webView, navigation: navigation) }
        if webView === signInBrowser {
            guard canNavigateSignInWindow else { return }
            let url = webView.url
            if signInNavigation?.finish(navigation, hasSupportedPage: Self.isSignInLocation(url),
                canClearWarning: url.flatMap(Self.validatedURL) != nil) == true { publishSignInStatus() }
            return
        }
        guard webView === browser, let navigation else { return }
        knownMainNavigations.add(navigation)
        if pending == nil {
            guard let observed = observedNavigation,
                  navigation === observed.navigation else { return }
            guard taskID == observed.taskID, observed.generation == generation,
                  let url = webView.url,
                  (observed.receivedMatchingCommit || Self.responseURL(observed.successfulResponseURL, matchesDocumentURL: url)),
                  Self.validatedURL(url) != nil else { endObservedNavigation(.finishRejected); return }
            // A committed page may replace its history URL before didFinish.
            // Keep the matching native commit on this exact navigation; the
            // final location remains an observation, never an action receipt.
            endObservedNavigation(.finished)
            let finishedScope = navigationCallbackScope(in: webView)
            let requiresExplicitHandback = !mayAct()
            guard isCurrentNavigationCallback(finishedScope) else { return }
            let evidence = NavigationHistory.PageObservation(taskID: observed.taskID, parentSessionID: browserSessionID,
                ownershipEpoch: ownershipEpoch, generation: generation, url: url, basis: .completedNavigation,
                navigationCorrelationID: observed.id, source: observed.startedWhileActive ? .activePageObservation : .userControlObservation,
                requiresExplicitHandback: requiresExplicitHandback)
            let page = ObservedPage(evidence: evidence, url: url, proof: .navigation)
            if observed.startedWhileActive { observedActivePage = page }
            else { observedUserPage = page }
            recordPageObservation(.accepted, page: page)
            let callback = navigationCallbackScope(in: webView)
            displayedSite = ComputerUseBrowserSite.displayName(for: url)
            guard isCurrentNavigationCallback(callback) else { return }
            let readyWhileActive = observed.startedWhileActive && mayAct()
            guard isCurrentNavigationCallback(callback) else { return }
            publish(.page(readyWhileActive ? .readyForTask : .readyForHandback, recovered: true))
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
        // Return the historical fact even if publication retires this owner;
        // the waiting caller separately rejects an obsolete current result.
        defer { pending.continuation.resume(returning: receipt) }
        let callback = browser.flatMap { navigationCallbackScope(in: $0) }
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        guard isCurrentNavigationCallback(callback) else { return }
        publish(.page(.opened, recovered: true))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if deferNavigationCallback(.navigationFailure, in: webView, navigation: navigation, replay: { [weak self] in
            self?.handleNavigationFailure(in: webView, navigation: navigation, error: error, recordCallback: false)
        }) { return }
        handleNavigationFailure(in: webView, navigation: navigation, error: error, recordCallback: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if deferNavigationCallback(.navigationFailure, in: webView, navigation: navigation, replay: { [weak self] in
            self?.handleNavigationFailure(in: webView, navigation: navigation, error: error, recordCallback: false)
        }) { return }
        handleNavigationFailure(in: webView, navigation: navigation, error: error, recordCallback: true)
    }

    private func handleNavigationFailure(in webView: WKWebView, navigation: WKNavigation?, error: Error, recordCallback: Bool) {
        guard prepareNavigationCallback(in: webView) else { return }
        guard !isRetiredNavigation(navigation, in: webView) else { return }
        if recordCallback { recordNavigationCallback(.navigationFailure, in: webView, navigation: navigation) }
        if webView === signInBrowser {
            guard canNavigateSignInWindow else { return }
            let failure = error as NSError
            let cancelled = failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
            if signInNavigation?.fail(navigation, cancelled: cancelled) == true { publishSignInStatus() }
            return
        }
        guard webView === browser, let navigation else { return }
        knownMainNavigations.add(navigation)
        if let observed = observedNavigation, navigation === observed.navigation {
            endObservedNavigation(.callbackFailed)
            retirePageObservations(.navigationFailed)
            publish(.issue(.navigation(.navigationFailed)))
            return
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        defer { resumeLocationDeliveryIfNeeded() }
        guard nativeRetirement == nil else { return }
        if let cleanup = processFailureCleanup {
            // A child and its opener can report termination during the same
            // native cleanup. Keep the parent's failure without recursing or
            // attributing the old notification to a replacement claim.
            if webView === cleanup.parent, retainsProcessFailureOwner(cleanup), !cleanup.parentFailed {
                recordNavigationSlot(.webContentTerminated, url: webView.url)
                cleanup.parentFailed = true
            }
            return
        }
        guard prepareNavigationCallback(in: webView) else { return }
        guard let parent = browser, webView === parent || webView === signInBrowser else { return }
        recordNavigationCallback(.webContentTerminated, in: webView, navigation: nil)
        let cleanup = ProcessFailureCleanup(parent: parent, taskID: taskID, sessionID: browserSessionID,
            ownershipEpoch: ownershipEpoch, parentFailed: webView === parent)
        processFailureCleanup = cleanup
        let controlsOwner = taskControls?.ownerID, controlsTask = taskControls?.taskID
        let child = detachSignInWindow()
        var failed: PendingNavigation?
        defer { failed?.continuation.resume(throwing: ComputerUseBrowserError.navigationFailed) }
        var invalidatedParent = false
        var projection = navigationCallbackScope(in: parent)
        func invalidateFailedParent() {
            guard cleanup.parentFailed, !invalidatedParent, retainsProcessFailureOwner(cleanup) else { return }
            invalidatedParent = true
            failed = pending.flatMap { detachPendingFailure(id: $0.id, error: .navigationFailed) }
            endObservedNavigation(.processTerminated)
            retirePageObservations(.processTerminated)
            generation &+= 1
            document = nil
            loadedPageIdentity = nil
            if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.pageChanged) }
            projection = navigationCallbackScope(in: parent)
        }
        invalidateFailedParent()
        if let child { finishSignInNativeCleanup(child) }
        invalidateFailedParent()
        if failed?.nativeDispatchStarted == true { parent.stopLoading() }
        // A real script callback can join its old slot during these calls.
        // The termination notification alone does not release that join or
        // prove whether a dispatched script/network effect happened.
        processFailureCleanup = nil
        func retainsProjection() -> Bool {
            retainsProcessFailureOwner(cleanup) && isCurrentNavigationCallback(projection)
                && taskControls?.ownerID == controlsOwner && taskControls?.taskID == controlsTask
        }
        guard retainsProjection() else { return }
        if signInSite != nil { signInSite = nil }
        guard retainsProjection() else { return }
        publish(.issue(invalidatedParent ? .parentProcessStopped : .signInProcessStopped))
        guard retainsProjection(), !invalidatedParent, let child,
              child.wasKey, window === child.parentWindow else { return }
        child.parentWindow?.makeKeyAndOrderFront(nil)
    }

    private func retainsProcessFailureOwner(_ cleanup: ProcessFailureCleanup) -> Bool {
        browser === cleanup.parent && taskID == cleanup.taskID && browserSessionID == cleanup.sessionID
            && ownershipEpoch == cleanup.ownershipEpoch
    }
}

private struct OwnedBrowserContent: View {
    @ObservedObject var context: ComputerUseOwnedBrowser
    let browser: WKWebView
    let surface: OwnedBrowserSurface
    var body: some View {
        let current = context.isCurrentMainView(browser)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text(current ? context.displayedSite : "Website unavailable").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityLabel("Website: \(current ? context.displayedSite : "Website unavailable")")
                    Text(current ? context.taskDetail : "Closed").font(.caption).fontWeight(.medium)
                    if current && context.taskID != nil { Text(context.pageDetail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let controls = context.controls(in: browser) {
                    if controls.phase == .paused {
                        Button("Let AI continue") { context.requestTaskControl(.resume, displayed: controls) }
                            .disabled(!controls.canResume || context.hasOpenSignInWindow)
                    } else {
                        Button("Take control") { context.requestTaskControl(.takeControl, displayed: controls) }
                    }
                    Button("Stop AI") { context.requestTaskControl(.stop, displayed: controls) }
                }
            }.padding(12)
            if current, let issue = context.pageIssue {
                Text(issue).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if current && context.hasOpenSignInWindow {
                Text("Finish or close the sign-in window before returning control to AI.")
                    .font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            OwnedBrowserMainWebView(surface: surface)
        }.frame(minWidth: 480, minHeight: 320)
    }
}

private struct OwnedBrowserSignInContent: View {
    @ObservedObject var context: ComputerUseOwnedBrowser
    let browser: WKWebView
    var body: some View {
        let current = context.isCurrentSignInView(browser)
        let site = current ? (context.signInSite ?? "Website unavailable") : "Website unavailable"
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(site)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityLabel("Website: \(site)")
                Text(current ? ComputerUseSignInPageStatus.controlDetail : "Sign-in window closed")
                    .font(.caption).foregroundStyle(.secondary)
                if current, let activity = context.signInPageDetail {
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
                if current, let issue = context.signInIssue { Text(issue).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Close sign-in window") { context.closeSignInWindow(in: browser) }.disabled(!current)
                    Spacer()
                    if let controls = context.controls(in: browser) {
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

private struct OwnedBrowserMainWebView: NSViewRepresentable {
    let surface: OwnedBrowserSurface
    func makeNSView(context: Context) -> OwnedBrowserSurface { surface }
    func updateNSView(_ nsView: OwnedBrowserSurface, context: Context) { }
}

/// A real native overlay inside the observed viewport. WebKit's snapshot does
/// not include AppKit subviews, so capture composites the actual rendered bar
/// at its actual location without changing the page's coordinate transform.
@MainActor
fileprivate final class OwnedBrowserSurface: NSView {
    let browser: WKWebView
    let findBar = OwnedBrowserFindBar()
    override var isFlipped: Bool { true }

    init(browser: WKWebView) {
        self.browser = browser
        super.init(frame: browser.frame)
        addSubview(browser); addSubview(findBar)
        findBar.isHidden = true
        findBar.onFind = { [weak self] backwards in
            Task { @MainActor [weak self] in
                do { try await self?.find(backwards: backwards) }
                catch { self?.findBar.status.stringValue = "Search unavailable" }
            }
        }
        findBar.onClose = { [weak self] in self?.hideFind() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        browser.frame = bounds
        findBar.frame = NSRect(x: max(0, bounds.width - 520), y: 0, width: min(520, bounds.width), height: 44)
    }
    func showFind() {
        findBar.isHidden = false
        layoutSubtreeIfNeeded()
        focusFind()
    }
    func focusFind() {
        window?.makeFirstResponder(findBar.query)
        findBar.query.selectText(nil)
    }
    func hideFind() {
        guard !findBar.isHidden else { return }
        let focused = findBar.editor != nil
        findBar.isHidden = true
        findBar.reset()
        if focused { window?.makeFirstResponder(browser) }
    }
    func find(backwards: Bool) async throws {
        guard !findBar.isHidden else { throw ComputerUseBrowserError.pageChanged }
        let query = findBar.query.stringValue, revision = UUID(), url = browser.url
        findBar.searchRevision = revision
        guard !query.isEmpty else { findBar.status.stringValue = ""; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try await browser.find(query, configuration: configuration)
        guard !findBar.isHidden, findBar.searchRevision == revision,
              findBar.query.stringValue == query, browser.url == url else { throw ComputerUseBrowserError.pageChanged }
        findBar.status.stringValue = result.matchFound ? "Match found" : "No matches"
    }
    func snapshotIncludingFindBar(webImage: NSImage) throws -> NSImage {
        layoutSubtreeIfNeeded()
        guard let source = webImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let barBitmap = findBar.bitmapImageRepForCachingDisplay(in: findBar.bounds),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ComputerUseBrowserError.pageEvidenceUnavailable
        }
        findBar.cacheDisplay(in: findBar.bounds, to: barBitmap)
        let barImage = NSImage(size: findBar.bounds.size); barImage.addRepresentation(barBitmap)
        let size = NSSize(width: source.pixelsWide, height: source.pixelsHigh)
        let scaleX = size.width / bounds.width, scaleY = size.height / bounds.height
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        webImage.draw(in: NSRect(origin: .zero, size: size))
        let rect = NSRect(x: findBar.frame.minX * scaleX, y: (bounds.height - findBar.frame.maxY) * scaleY,
                          width: findBar.frame.width * scaleX, height: findBar.frame.height * scaleY)
        barImage.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size); image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
fileprivate final class OwnedBrowserFindBar: NSView, NSSearchFieldDelegate {
    struct State: Equatable, Sendable {
        let visible: Bool
        let query: String
        let selection: NSRange?
        let marked: Bool
        let revision: UUID
        let status: String
    }
    let query = NSSearchField()
    let status = NSTextField(labelWithString: "")
    let previous = NSButton(title: "↑", target: nil, action: nil)
    let next = NSButton(title: "↓", target: nil, action: nil)
    let done = NSButton(title: "Done", target: nil, action: nil)
    var searchRevision = UUID()
    var onFind: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var editor: NSTextView? { query.currentEditor() as? NSTextView }
    var state: State { .init(visible: !isHidden, query: query.stringValue, selection: editor?.selectedRange(), marked: editor?.hasMarkedText() ?? false, revision: searchRevision, status: status.stringValue) }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        query.identifier = NSUserInterfaceItemIdentifier("owned-browser-find-query")
        query.placeholderString = "Find in page"
        query.setAccessibilityLabel("Find in page")
        query.delegate = self
        query.sendsSearchStringImmediately = false
        query.sendsWholeSearchString = true
        query.target = self; query.action = #selector(nextMatch)
        previous.target = self; previous.action = #selector(previousMatch)
        next.target = self; next.action = #selector(nextMatch)
        done.target = self; done.action = #selector(closeFind)
        previous.setAccessibilityLabel("Previous match"); next.setAccessibilityLabel("Next match")
        status.font = .systemFont(ofSize: 11)
        [query, status, previous, next, done].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        let width = bounds.width
        query.frame = NSRect(x: 8, y: 9, width: max(80, width - 225), height: 26)
        status.frame = NSRect(x: width - 209, y: 16, width: 78, height: 16)
        previous.frame = NSRect(x: width - 130, y: 8, width: 32, height: 28)
        next.frame = NSRect(x: width - 98, y: 8, width: 32, height: 28)
        done.frame = NSRect(x: width - 64, y: 8, width: 58, height: 28)
    }
    func reset() { query.stringValue = ""; status.stringValue = ""; searchRevision = UUID() }
    func controlTextDidChange(_ notification: Notification) { searchRevision = UUID(); status.stringValue = "" }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { onFind?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
        return false
    }
    @objc private func nextMatch() { onFind?(false) }
    @objc private func previousMatch() { onFind?(true) }
    @objc private func closeFind() { onClose?() }
}

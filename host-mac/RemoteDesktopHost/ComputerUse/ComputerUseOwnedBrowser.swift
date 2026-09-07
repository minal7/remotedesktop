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

enum ComputerUseBrowserError: Error, LocalizedError, Equatable {
    case invalidURL, busy, ownershipLost, pageChanged, navigationFailed, deadlineExceeded, closed, unsupportedDocument, pageEvidenceUnavailable, documentUnresponsive, windowNotActive, authenticationRequired, signInWindowOpen, viewportScrollUnavailable, viewportScrollUncertain
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
        }
    }
}

/// Owns one visible WebKit context. It never addresses Safari/Chrome windows,
/// imports their cookies, or accepts model-supplied JavaScript. Navigation
/// receipts come from the exact WKNavigation owned by the current task.
@MainActor
final class ComputerUseOwnedBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
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
    private var document: ComputerUseBrowserDocument?
    private var receipts: [String: ComputerUseBrowserDocument] = [:]
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
    private var signInWindow: NSWindow?
    private var signInURLObservation: NSKeyValueObservation?
    private var signInScope: (taskID: String, ownerID: UUID)?

    private struct ObservedNavigation {
        let navigation: WKNavigation
        let generation: UInt64
        let taskID: String
        let startedWhileActive: Bool
        var successfulResponseURL: URL?
    }

    private struct ObservedPage {
        enum Proof { case navigation, sameDocument(String) }
        let id: UUID
        let generation: UInt64
        let url: URL
        let proof: Proof
        var requiresExplicitHandback = false
    }

    private struct PendingDOM {
        let id: UUID
        var continuation: CheckedContinuation<String, Error>?
        var timeout: Task<Void, Never>?
    }

    private struct PendingNavigation {
        let id: UUID
        let taskID: String
        let generation: UInt64
        let operationID: String
        let requestedURL: URL
        let continuation: CheckedContinuation<ComputerUseBrowserDocument, Error>
        var navigation: WKNavigation?
        var receivedSuccessfulResponse = false
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
    /// sections 3.5 and 6.1). This comparison is only for a successful response
    /// on the observed WKNavigation; retained document checks stay exact.
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
            ownershipEpoch = UUID()
            self.taskID = taskID
            generation &+= 1
            document = nil
            observedUserPage = nil
            observedActivePage = nil
            receipts.removeAll()
        }
    }

    func hasOwnership(taskID: String) -> Bool { self.taskID == taskID && mayAct() && !hasOpenSignInWindow }

    var hasOpenSignInWindow: Bool { signInBrowser != nil }

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

    func reacquireAfterUserControl(taskID: String) async throws {
        try Task.checkCancellation()
        guard browser != nil, self.taskID == taskID || isFrontmostWindow else { return }
        guard !hasOpenSignInWindow else { throw ComputerUseBrowserError.signInWindowOpen }
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil,
              browser?.isLoading == false else { throw ComputerUseBrowserError.busy }
        // An unchanged document needs no new navigation or invented receipt.
        if let document, validate(document) { return }
        if let observed = observedUserPage {
            try await adoptPageObservation(observed, source: .userControlObservation, taskID: taskID)
        } else if let observed = observedActivePage {
            // A page observed during automation remains that kind of evidence
            // when explicitly handed back later. It is never an action receipt.
            try await adoptPageObservation(observed, source: .activePageObservation, taskID: taskID)
        } else { throw ComputerUseBrowserError.pageChanged }
        detail = "Control returned — checking the current page"
    }

    private func adoptPageObservation(_ observed: ObservedPage, source: ComputerUseBrowserDocument.Source,
                                      taskID: String) async throws {
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
            observedUserPage = nil
            observedActivePage = nil
            loadedPageIdentity = nil
            throw ComputerUseBrowserError.pageChanged
        }
        try claim(taskID: taskID)
        document = ComputerUseBrowserDocument(contextID: contextID, taskID: taskID,
            generation: generation, operationID: "page-observation-\(observed.id.uuidString)",
            requestedURL: observed.url, committedURL: observed.url, source: source)
        // This observation is deliberately absent from `receipts`. The URL
        // records observed location, not a requested/executed navigation.
        observedUserPage = nil
        observedActivePage = nil
        loadedPageIdentity = identity
        detail = "Checking the current page"
    }

    func callDOM(_ command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                 document expected: ComputerUseBrowserDocument) async throws -> ComputerUseBrowserDOMReply {
        try await callDOM(command, arguments: arguments, validateContext: { self.validate(expected) })
    }

    func observePage(document expected: ComputerUseBrowserDocument) async throws -> ComputerUseBrowserPageEvidence {
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let result = try await callDOM(.pageSnapshot, arguments: [:], document: expected)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard result.status == "page-snapshot", result.fields == nil,
              let page = result.page, page.isWellFormed else { throw ComputerUseBrowserError.pageEvidenceUnavailable }
        return ComputerUseBrowserPageEvidence(document: expected, documentID: result.documentID, page: page)
    }

    /// The browser/document gate is rechecked around WebKit's await; the
    /// script separately re-reads text, rendering and destinations. A fresh
    /// read replaces the prior observation rather than extending its lease.
    func validatePageEvidence(_ evidence: ComputerUseBrowserPageEvidence) async throws {
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        let result = try await callDOM(.validatePageSnapshot,
            arguments: ["documentID": evidence.documentID, "snapshotID": evidence.page.id], document: evidence.document)
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        guard result.status == "page-current", result.documentID == evidence.documentID,
              result.fields == nil, result.page == nil else { throw ComputerUseBrowserError.pageChanged }
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
                         validateContext: () -> Bool) async throws -> ComputerUseBrowserDOMReply {
        try Task.checkCancellation()
        guard validateContext(), let browser else { throw ComputerUseBrowserError.pageChanged }
        guard pendingDOM == nil else { throw ComputerUseBrowserError.busy }
        let id = UUID()
        let source = try await withTaskCancellationHandler {
            do {
                let source: String = try await withCheckedThrowingContinuation { continuation in
                    pendingDOM = PendingDOM(id: id, continuation: continuation)
                    pendingDOM?.timeout = Task { [weak self, domTimeout] in
                        do { try await Task.sleep(for: domTimeout) } catch { return }
                        self?.interruptDOM(id: id, error: ComputerUseBrowserError.documentUnresponsive)
                    }
                    browser.callAsyncJavaScript(ComputerUseBrowserDOM.invocation,
                        arguments: ["command": command.rawValue, "args": arguments], in: nil, in: ComputerUseBrowserDOM.world) { [weak self] result in
                        guard let self, let pending = pendingDOM, pending.id == id else { return }
                        pendingDOM = nil
                        pending.timeout?.cancel()
                        switch result {
                        case .success(let value):
                            guard let source = value as? String, source.utf8.count <= 8 * 1_024 * 1_024 else {
                                pending.continuation?.resume(throwing: ComputerUseBrowserError.unsupportedDocument)
                                return
                            }
                            pending.continuation?.resume(returning: source)
                        case .failure: pending.continuation?.resume(throwing: ComputerUseBrowserError.pageChanged)
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
        let result = try JSONDecoder().decode(ComputerUseBrowserDOMReply.self, from: Data(source.utf8))
        guard result.scroll == nil || command == .scrollViewport || command == .viewportScrollReceipt else {
            throw ComputerUseBrowserError.unsupportedDocument
        }
        guard result.documentID.utf8.count == 32,
              result.documentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.pageChanged
        }
        if result.status == "authentication-required" {
            guard result.fields == nil, result.page == nil, result.scroll == nil else { throw ComputerUseBrowserError.unsupportedDocument }
            throw ComputerUseBrowserError.authenticationRequired
        }
        return result
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
                  from expectedDocument: ComputerUseBrowserDocument? = nil) async throws -> ComputerUseBrowserDocument {
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil, pendingDOM == nil, observedNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard receipts[operationID] == nil, receipts.count < 64, !operationID.isEmpty else {
            // An uncertain navigation is reconciled by the step engine. This
            // adapter never reissues a completed operation ID on its own.
            throw ComputerUseBrowserError.pageChanged
        }
        guard let url = Self.validatedURL(url) else { throw ComputerUseBrowserError.invalidURL }
        if let expectedDocument, !validate(expectedDocument) { throw ComputerUseBrowserError.pageChanged }
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
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        observedActivePage = nil
        observedUserPage = nil
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        detail = "Opening page…"
        let id = UUID()
        return try await withTaskCancellationHandler {
            do {
                let result: ComputerUseBrowserDocument = try await withCheckedThrowingContinuation { continuation in
                    pending = PendingNavigation(id: id, taskID: taskID, generation: generation,
                        operationID: operationID, requestedURL: url, continuation: continuation)
                    pending?.timeout = Task { [weak self, navigationTimeout] in
                        do { try await Task.sleep(for: navigationTimeout) } catch { return }
                        self?.failPending(id: id, error: .deadlineExceeded)
                    }
                    pending?.navigation = browser.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                    if pending?.navigation == nil { failPending(id: id, error: .navigationFailed) }
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

    func stop() {
        closeSignInWindow(restoreParent: false)
        if let pending { failPending(id: pending.id, error: .ownershipLost) }
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.ownershipLost) }
        taskID = nil
        ownershipEpoch = UUID()
        generation &+= 1
        document = nil
        observedNavigation = nil
        observedUserPage = nil
        observedActivePage = nil
        loadedPageIdentity = nil
        browser?.stopLoading()
        detail = "Stopped"
    }

    func close() {
        stop()
        window?.delegate = nil
        window?.close()
        window?.contentView = nil
        window = nil
        releaseBrowser()
    }

    private func releaseBrowser() {
        closeSignInWindow(restoreParent: false)
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.closed) }
        pendingDOM = nil
        observedNavigation = nil
        observedUserPage = nil
        observedActivePage = nil
        loadedPageIdentity = nil
        urlObservation = nil
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        browser = nil
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
        stop()
        window?.contentView = nil
        window = nil
        releaseBrowser()
        detail = "Closed"
    }

    private func makeBrowser() -> WKWebView {
        if let browser { return browser }
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
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        let changed = document.map { $0.committedURL != url } ?? false
        let observedChanged = (observedUserPage.map { $0.url != url } ?? false)
            || (observedActivePage.map { $0.url != url } ?? false)
        guard pending == nil, changed || observedChanged || !ordered else { return }
        let previousIdentity = loadedPageIdentity
        generation &+= 1
        document = nil
        observedUserPage = nil
        observedActivePage = nil
        if ordered, taskID != nil, !view.isLoading, observedNavigation == nil,
           let previousIdentity, let url, Self.validatedURL(url) != nil {
            let observation = ObservedPage(id: UUID(), generation: generation,
                url: url, proof: .sameDocument(previousIdentity))
            if mayAct() { observedActivePage = observation }
            else { observedUserPage = observation }
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
        // Retire delegate identity before stopping/closing: late child callbacks
        // can neither close a replacement nor change the main page's evidence.
        signInBrowser = nil
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
        self.pending = nil
        pending.timeout?.cancel()
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        detail = error.localizedDescription
        browser?.stopLoading()
        pending.continuation.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if webView === signInBrowser {
            guard canNavigateSignInWindow, let frame = navigationAction.targetFrame else {
                decisionHandler(.cancel)
                return
            }
            let permitted = frame.isMainFrame ? Self.isSignInLocation(navigationAction.request.url)
                : ["http", "https", "about", "data", "blob"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
            if !permitted { signInDetail = "This sign-in destination is not supported in the AI browser. Close this window to return." }
            decisionHandler(permitted ? .allow : .cancel)
            return
        }
        guard webView === browser else { decisionHandler(.cancel); return }
        // A popup cannot consume the main navigation's continuation. Admission
        // is rechecked when WebKit asks for the concrete child configuration.
        guard let frame = navigationAction.targetFrame else {
            decisionHandler(canOpenSignInWindow && Self.isSignInCreationLocation(navigationAction.request.url) ? .allow : .cancel)
            return
        }
        guard frame.isMainFrame else {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        guard let url = navigationAction.request.url, Self.validatedURL(url) != nil else {
            decisionHandler(.cancel)
            if let pending { failPending(id: pending.id, error: .invalidURL) }
            return
        }
        if let pending, !hasOwnership(taskID: pending.taskID) {
            decisionHandler(.cancel)
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if webView === signInBrowser {
            guard canNavigateSignInWindow else { decisionHandler(.cancel); return }
            guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
            // Error pages may explain a provider refusal to the person. They
            // are display only and never become task/navigation evidence.
            let permitted = navigationResponse.canShowMIMEType && Self.isSignInLocation(navigationResponse.response.url)
            if !permitted { signInDetail = "The sign-in page cannot be displayed. Close this window to return." }
            decisionHandler(permitted ? .allow : .cancel)
            return
        }
        guard webView === browser else { decisionHandler(.cancel); return }
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        guard navigationResponse.canShowMIMEType,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let url = response.url, Self.validatedURL(url) != nil else {
            decisionHandler(.cancel)
            observedNavigation = nil
            observedUserPage = nil
            observedActivePage = nil
            if let pending { failPending(id: pending.id, error: .navigationFailed) }
            return
        }
        pending?.receivedSuccessfulResponse = true
        observedNavigation?.successfulResponseURL = response.url
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browser else { return }
        guard let pending else {
            generation &+= 1
            document = nil
            loadedPageIdentity = nil
            observedUserPage = nil
            observedActivePage = nil
            observedNavigation = nil
            if let navigation, let taskID {
                observedNavigation = ObservedNavigation(navigation: navigation, generation: generation,
                    taskID: taskID, startedWhileActive: mayAct())
            }
            detail = "Page changed"
            return
        }
        guard navigation === pending.navigation else { failPending(id: pending.id, error: .pageChanged); return }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browser else { return }
        if pending == nil {
            guard let observed = observedNavigation,
                  navigation === observed.navigation else { return }
            observedNavigation = nil
            guard taskID == observed.taskID, observed.generation == generation,
                  let url = webView.url, Self.responseURL(observed.successfulResponseURL, matchesDocumentURL: url),
                  Self.validatedURL(url) != nil else { return }
            let page = ObservedPage(id: UUID(), generation: generation, url: url, proof: .navigation,
                requiresExplicitHandback: !mayAct())
            if observed.startedWhileActive { observedActivePage = page }
            else { observedUserPage = page }
            displayedSite = ComputerUseBrowserSite.displayName(for: url)
            detail = observed.startedWhileActive && mayAct() ? "Page ready — checking the current task"
                : "Page ready — choose Let AI continue when you are finished"
            return
        }
        guard let pending, navigation === pending.navigation else { return }
        guard hasOwnership(taskID: pending.taskID), pending.generation == generation,
              pending.receivedSuccessfulResponse, let url = webView.url, Self.validatedURL(url) != nil else {
            failPending(id: pending.id, error: .ownershipLost)
            return
        }
        let receipt = ComputerUseBrowserDocument(contextID: contextID, taskID: pending.taskID,
            generation: generation, operationID: pending.operationID, requestedURL: pending.requestedURL, committedURL: url)
        self.pending = nil
        pending.timeout?.cancel()
        document = receipt
        receipts[pending.operationID] = receipt
        displayedSite = ComputerUseBrowserSite.displayName(for: url)
        detail = "Page opened"
        pending.continuation.resume(returning: receipt)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === signInBrowser {
            signInDetail = "The sign-in page did not finish loading. Close this window to return."
            return
        }
        guard webView === browser else { return }
        if let observed = observedNavigation, navigation === observed.navigation {
            observedNavigation = nil; observedUserPage = nil; observedActivePage = nil
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === signInBrowser {
            signInDetail = "The sign-in page did not finish loading. Close this window to return."
            return
        }
        guard webView === browser else { return }
        if let observed = observedNavigation, navigation === observed.navigation {
            observedNavigation = nil; observedUserPage = nil; observedActivePage = nil
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === signInBrowser {
            closeSignInWindow()
            detail = "The sign-in window stopped. Check the main page before continuing."
            return
        }
        guard webView === browser else { return }
        closeSignInWindow(restoreParent: false)
        if let pending { failPending(id: pending.id, error: .navigationFailed) }
        generation &+= 1
        document = nil
        loadedPageIdentity = nil
        observedNavigation = nil
        observedUserPage = nil
        observedActivePage = nil
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

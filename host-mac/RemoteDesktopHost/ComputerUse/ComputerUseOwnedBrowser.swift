import AppKit
import SwiftUI
import WebKit

struct ComputerUseBrowserDocument: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case automationNavigation
        case userControlObservation
    }
    let contextID: String
    let taskID: String
    let generation: UInt64
    let operationID: String
    let requestedURL: URL
    let committedURL: URL
    let source: Source

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

enum ComputerUseBrowserError: Error, LocalizedError, Equatable {
    case invalidURL, busy, ownershipLost, pageChanged, navigationFailed, deadlineExceeded, closed, unsupportedDocument, documentUnresponsive, windowNotActive
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
        case .documentUnresponsive: return "The AI browser page did not respond before the deadline. Check it before continuing."
        case .windowNotActive: return "The AI browser is open, but another Mac window still has focus. Select the AI browser, then continue."
        }
    }
}

/// Owns one visible WebKit context. It never addresses Safari/Chrome windows,
/// imports their cookies, or accepts model-supplied JavaScript. Navigation
/// receipts come from the exact WKNavigation owned by the current task.
@MainActor
final class ComputerUseOwnedBrowser: NSObject, ObservableObject, WKNavigationDelegate, NSWindowDelegate {
    let contextID = UUID().uuidString
    @Published private(set) var displayedURL = ""
    @Published private(set) var detail = "Ready"
    private(set) var taskID: String?
    private var generation: UInt64 = 0
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
    private var userNavigation: UserNavigation?
    private var observedUserPage: ObservedUserPage?

    private struct UserNavigation {
        let navigation: WKNavigation
        let generation: UInt64
        var successfulResponseURL: URL?
    }

    private struct ObservedUserPage {
        let id: UUID
        let generation: UInt64
        let url: URL
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

    func claim(taskID: String) throws {
        guard pending == nil, pendingDOM == nil, userNavigation == nil else { throw ComputerUseBrowserError.busy }
        guard mayAct(), !taskID.isEmpty else { throw ComputerUseBrowserError.ownershipLost }
        if self.taskID != taskID {
            self.taskID = taskID
            generation &+= 1
            document = nil
            observedUserPage = nil
            receipts.removeAll()
        }
    }

    func hasOwnership(taskID: String) -> Bool { self.taskID == taskID && mayAct() }

    var isFrontmostWindow: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        return NSApp.keyWindow === window
    }

    var hasRequiredPresentation: Bool { !presentsWindow || isFrontmostWindow }

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
    var isLoadingPage: Bool { browser?.isLoading == true || pending != nil || userNavigation != nil }

    var hasPageAwaitingHandback: Bool {
        guard let observedUserPage else { return false }
        return observedUserPage.generation == generation && pending == nil
            && userNavigation == nil && browser?.isLoading == false
            && browser?.url == observedUserPage.url
    }

    func reacquireAfterUserControl(taskID: String) throws {
        guard browser != nil, self.taskID == taskID || isFrontmostWindow else { return }
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil, pendingDOM == nil, userNavigation == nil,
              browser?.isLoading == false else { throw ComputerUseBrowserError.busy }
        // An unchanged document needs no new navigation or invented receipt.
        if let document, validate(document) { return }
        guard let observed = observedUserPage, hasPageAwaitingHandback else {
            throw ComputerUseBrowserError.pageChanged
        }
        try claim(taskID: taskID)
        document = ComputerUseBrowserDocument(contextID: contextID, taskID: taskID,
            generation: generation, operationID: "user-observation-\(observed.id.uuidString)",
            requestedURL: observed.url, committedURL: observed.url, source: .userControlObservation)
        // This observation is deliberately absent from `receipts`. The URL
        // records observed location, not a requested/executed navigation.
        observedUserPage = nil
        detail = "Control returned — checking the current page"
    }

    func callDOM(_ command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                 document expected: ComputerUseBrowserDocument) async throws -> ComputerUseBrowserDOMReply {
        try Task.checkCancellation()
        guard validate(expected), let browser else { throw ComputerUseBrowserError.pageChanged }
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
        guard validate(expected) else { throw ComputerUseBrowserError.pageChanged }
        let result = try JSONDecoder().decode(ComputerUseBrowserDOMReply.self, from: Data(source.utf8))
        guard result.documentID.utf8.count == 32,
              result.documentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserError.pageChanged
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
        guard pending == nil, pendingDOM == nil else { throw ComputerUseBrowserError.busy }
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
        displayedURL = url.absoluteString
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
        if let pending { failPending(id: pending.id, error: .ownershipLost) }
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.ownershipLost) }
        taskID = nil
        generation &+= 1
        document = nil
        userNavigation = nil
        observedUserPage = nil
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
        if let pendingDOM { interruptDOM(id: pendingDOM.id, error: ComputerUseBrowserError.closed) }
        pendingDOM = nil
        userNavigation = nil
        observedUserPage = nil
        urlObservation = nil
        browser?.navigationDelegate = nil
        browser = nil
    }

    func windowWillClose(_ notification: Notification) {
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
        configuration.userContentController.addUserScript(WKUserScript(source: ComputerUseBrowserDOM.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ComputerUseBrowserDOM.world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        view.navigationDelegate = self
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] _, change in
            let url = change.newValue ?? nil
            Task { @MainActor [weak self] in
                guard let self, browser?.url == url else { return }
                if let url { displayedURL = url.absoluteString }
                let currentLocationChanged = document.map { $0.committedURL != url } ?? false
                let observedLocationChanged = observedUserPage.map { $0.url != url } ?? false
                if pending == nil, currentLocationChanged || observedLocationChanged {
                    generation &+= 1
                    self.document = nil
                    observedUserPage = nil
                    detail = "Page changed"
                }
            }
        }
        browser = view
        return view
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
        detail = error.localizedDescription
        browser?.stopLoading()
        pending.continuation.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === browser else { decisionHandler(.cancel); return }
        // A popup or unsupported subframe is not the task's main navigation.
        // Cancelling it must not consume that navigation's continuation.
        guard let frame = navigationAction.targetFrame else { decisionHandler(.cancel); return }
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
        guard webView === browser else { decisionHandler(.cancel); return }
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        guard navigationResponse.canShowMIMEType,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let url = response.url, Self.validatedURL(url) != nil else {
            decisionHandler(.cancel)
            userNavigation = nil
            observedUserPage = nil
            if let pending { failPending(id: pending.id, error: .navigationFailed) }
            return
        }
        pending?.receivedSuccessfulResponse = true
        userNavigation?.successfulResponseURL = response.url
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browser else { return }
        guard let pending else {
            generation &+= 1
            document = nil
            observedUserPage = nil
            userNavigation = nil
            if !mayAct(), let navigation {
                userNavigation = UserNavigation(navigation: navigation, generation: generation)
            }
            detail = "Page changed"
            return
        }
        guard navigation === pending.navigation else { failPending(id: pending.id, error: .pageChanged); return }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browser else { return }
        if pending == nil {
            guard let observed = userNavigation,
                  navigation === observed.navigation else { return }
            userNavigation = nil
            guard !mayAct(), observed.generation == generation,
                  let url = webView.url, observed.successfulResponseURL == url,
                  Self.validatedURL(url) != nil else { return }
            observedUserPage = ObservedUserPage(id: UUID(), generation: generation, url: url)
            displayedURL = url.absoluteString
            detail = "Page ready — choose Resume when you are finished"
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
        displayedURL = url.absoluteString
        detail = "Page opened"
        pending.continuation.resume(returning: receipt)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === browser else { return }
        if let observed = userNavigation, navigation === observed.navigation {
            userNavigation = nil; observedUserPage = nil
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === browser else { return }
        if let observed = userNavigation, navigation === observed.navigation {
            userNavigation = nil; observedUserPage = nil
        }
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === browser else { return }
        if let pending { failPending(id: pending.id, error: .navigationFailed) }
        generation &+= 1
        document = nil
        userNavigation = nil
        observedUserPage = nil
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
                    Text(context.displayedURL).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(context.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Stop") { context.stop() }
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

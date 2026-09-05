import AppKit
import SwiftUI
import WebKit

struct ComputerUseBrowserDocument: Equatable, Sendable {
    let contextID: String
    let taskID: String
    let generation: UInt64
    let operationID: String
    let requestedURL: URL
    let committedURL: URL
}

enum ComputerUseBrowserError: Error, LocalizedError, Equatable {
    case invalidURL, busy, ownershipLost, pageChanged, navigationFailed, deadlineExceeded, closed
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The browser needs an HTTP or HTTPS URL without embedded credentials."
        case .busy: return "The AI browser already has a navigation in progress."
        case .ownershipLost: return "Control of the AI browser changed before the operation finished."
        case .pageChanged: return "The browser page changed. Its previous document reference is no longer valid."
        case .navigationFailed: return "The requested page could not be opened successfully."
        case .deadlineExceeded: return "The browser did not finish opening the page before the deadline."
        case .closed: return "The AI browser window was closed."
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
    private var browser: WKWebView?
    private var window: NSWindow?
    private var urlObservation: NSKeyValueObservation?
    private var pending: PendingNavigation?

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

    init(presentsWindow: Bool = true, navigationTimeout: Duration = .seconds(30), mayAct: @escaping () -> Bool) {
        self.presentsWindow = presentsWindow
        self.navigationTimeout = navigationTimeout
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
        guard pending == nil else { throw ComputerUseBrowserError.busy }
        guard mayAct(), !taskID.isEmpty else { throw ComputerUseBrowserError.ownershipLost }
        if self.taskID != taskID {
            self.taskID = taskID
            generation &+= 1
            document = nil
            receipts.removeAll()
        }
    }

    func hasOwnership(taskID: String) -> Bool { self.taskID == taskID && mayAct() }

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

    func navigate(taskID: String, operationID: String, to url: URL) async throws -> ComputerUseBrowserDocument {
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
        guard pending == nil else { throw ComputerUseBrowserError.busy }
        guard receipts[operationID] == nil, receipts.count < 64, !operationID.isEmpty else {
            // An uncertain navigation is reconciled by the step engine. This
            // adapter never reissues a completed operation ID on its own.
            throw ComputerUseBrowserError.pageChanged
        }
        guard let url = Self.validatedURL(url) else { throw ComputerUseBrowserError.invalidURL }
        let browser = makeBrowser()
        presentIfNeeded(browser)
        try Task.checkCancellation()
        guard hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
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
                try Task.checkCancellation()
                guard validate(result) else { throw ComputerUseBrowserError.ownershipLost }
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
        taskID = nil
        generation &+= 1
        document = nil
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
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        view.navigationDelegate = self
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] _, change in
            let url = change.newValue ?? nil
            Task { @MainActor [weak self] in
                guard let self, browser?.url == url else { return }
                if let url { displayedURL = url.absoluteString }
                if pending == nil, let document, document.committedURL != url {
                    generation &+= 1
                    self.document = nil
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
        NSApp.activate(ignoringOtherApps: false)
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
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        guard navigationResponse.canShowMIMEType,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let url = response.url, Self.validatedURL(url) != nil else {
            decisionHandler(.cancel)
            if let pending { failPending(id: pending.id, error: .navigationFailed) }
            return
        }
        pending?.receivedSuccessfulResponse = true
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let pending else {
            generation &+= 1
            document = nil
            detail = "Page changed"
            return
        }
        guard navigation === pending.navigation else { failPending(id: pending.id, error: .pageChanged); return }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let pending, navigation === pending.navigation { failPending(id: pending.id, error: .navigationFailed) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let pending { failPending(id: pending.id, error: .navigationFailed) }
        generation &+= 1
        document = nil
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

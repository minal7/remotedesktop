import Foundation

enum ComputerUseBrowserInitialSearchError: Error, Equatable { case invalidRequest, pendingStage, busy, retired }

/// Supplied by host configuration/selection, never decoded from model output.
/// Choosing a provider consistently with the complete goal remains the
/// driver's responsibility. Constructing this value does not select one.
struct ComputerUseBrowserSearchProvider: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let endpoint: URL
    private let parameter: String
    let digest: String
    var description: String { "BrowserSearchProvider" }
    var debugDescription: String { description }

    init(endpoint: URL, queryParameter: String) throws {
        guard endpoint.absoluteString.utf8.count <= 1_024,
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(),
              parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http"
                && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              ComputerUseOwnedBrowser.validatedURL(endpoint) == endpoint,
              (1...32).contains(queryParameter.utf8.count),
              queryParameter.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw ComputerUseBrowserInitialSearchError.invalidRequest
        }
        self.endpoint = endpoint; parameter = queryParameter
        digest = ComputerUseTaskContract.digest(["browser-search-provider-v1", endpoint.absoluteString, queryParameter])
    }

    fileprivate func destination(query: String) throws -> URL {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ComputerUseBrowserInitialSearchError.invalidRequest
        }
        // Encode bytes, including literal '+', so form-query decoding cannot
        // turn source punctuation into spaces or extra query parameters.
        let encoded = query.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
        parts.percentEncodedQuery = parameter + "=" + encoded
        guard let url = parts.url, url.absoluteString.utf8.count <= 8_192,
              ComputerUseOwnedBrowser.validatedURL(url) == url else { throw ComputerUseBrowserInitialSearchError.invalidRequest }
        return url
    }
}

struct ComputerUseBrowserInitialSearchRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let goal: ComputerUseBrowserGoalInput
    let queryDigest: String
    let providerDigest: String
    let destination: URL
    let digest: String
    var description: String { "BrowserInitialSearchRequest" }
    var debugDescription: String { description }

    init(interpretation: ComputerUseBrowserGoalProposal, query: ComputerUseBrowserSearchQuery,
         provider: ComputerUseBrowserSearchProvider) throws {
        guard interpretation.disposition == .research, query.goalDigest == interpretation.input.digest,
              query.interpretationDigest == interpretation.digest, let text = query.query else {
            throw ComputerUseBrowserInitialSearchError.invalidRequest
        }
        goal = interpretation.input; queryDigest = query.digest; providerDigest = provider.digest
        destination = try provider.destination(query: text)
        digest = ComputerUseTaskContract.digest(["browser-initial-search-request-v1", goal.digest,
            query.digest, provider.digest, destination.absoluteString])
    }
}

/// One immutable first-search stage per research root. Journal identities do
/// not vary with query, provider, answer, browser replacement or model output.
/// A returned native document is historical navigation evidence, not results
/// validation or completion of the research task.
@MainActor
final class ComputerUseBrowserInitialSearch {
    enum RefreshResult: Equatable, Sendable { case noPendingStage, requiresReconciliation, unchanged, updated }
    private struct StartingPoint {
        let document: ComputerUseBrowserDocument?
        let documentID: String?
        let identity: ComputerUseTaskJournal
    }
    let request: ComputerUseBrowserInitialSearchRequest
    private let session: ComputerUseBrowserHandbackRequirement
    private var startingPoint: StartingPoint
    // A write can replace the file before its final fsync fails. Retain both
    // known bindings until a fresh, leased read identifies the visible one.
    private var unconfirmedReplacement: StartingPoint?
    private let browser: ComputerUseOwnedBrowser
    private let directory: URL
    private let makeStore: (URL) throws -> ComputerUseTaskJournalStore
    private let operationID: String
    private var isExecuting = false
    private var isRetired = false
    private(set) var isPending = true

    init(request: ComputerUseBrowserInitialSearchRequest, session: ComputerUseBrowserHandbackRequirement,
         browser: ComputerUseOwnedBrowser, directory: URL,
         startingPage: ComputerUseBrowserPageEvidence? = nil,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        guard request.goal.taskID == session.taskID else { throw ComputerUseBrowserInitialSearchError.invalidRequest }
        try browser.validateWorkflowSession(session)
        if let startingPage {
            guard startingPage.document.taskID == request.goal.taskID, browser.validate(startingPage.document) else {
                throw ComputerUseBrowserError.pageChanged
            }
        }
        self.request = request; self.session = session; self.browser = browser
        self.directory = directory.appendingPathComponent("Initial Search", isDirectory: true); self.makeStore = makeStore
        operationID = ComputerUseTaskContract.digest(["browser-initial-search-stage-v1", request.goal.taskID])
        startingPoint = Self.startingPoint(request: request, session: session, operationID: operationID, page: startingPage)
    }

    private static func startingPoint(request: ComputerUseBrowserInitialSearchRequest,
        session: ComputerUseBrowserHandbackRequirement, operationID: String, page: ComputerUseBrowserPageEvidence?) -> StartingPoint {
        var binding = ["browser-initial-search-binding-v1", request.digest, session.sessionBindingDigest]
        if let startingPage = page {
            binding += ["observed-starting-document-v1", startingPage.documentID,
                startingPage.document.contextID, String(startingPage.document.generation), startingPage.document.operationID,
                startingPage.document.committedURL.absoluteString]
        }
        let identity = ComputerUseTaskJournal(taskID: ComputerUseTaskContract.digest(["browser-initial-search-record-v1", request.goal.taskID]),
            promptDigest: request.goal.rootDigest,
            contractDigest: ComputerUseTaskContract.digest(binding),
            stepIDs: [operationID], statuses: [.planned])
        return .init(document: page?.document, documentID: page?.documentID, identity: identity)
    }

    private static func matches(_ saved: ComputerUseTaskJournal, _ expected: ComputerUseTaskJournal) -> Bool {
        saved.taskID == expected.taskID && saved.promptDigest == expected.promptDigest
            && saved.contractDigest == expected.contractDigest && saved.stepIDs == expected.stepIDs && saved.statuses.count == 1
    }

    private func point(matching saved: ComputerUseTaskJournal?) throws -> StartingPoint {
        guard let saved else { return startingPoint }
        if Self.matches(saved, startingPoint.identity) { return startingPoint }
        if let replacement = unconfirmedReplacement, Self.matches(saved, replacement.identity) { return replacement }
        throw ComputerUseTaskExecutionError.journalMismatch
    }

    func open(checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserDocument {
        guard !isExecuting else { throw ComputerUseBrowserInitialSearchError.busy }
        guard !isRetired else { throw ComputerUseBrowserInitialSearchError.retired }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw ComputerUseBrowserInitialSearchError.retired }
            try checkCurrent()
            try browser.validateWorkflowSession(session)
        }
        try check()
        let store = try makeStore(directory)
        var persisted = try store.load(taskID: startingPoint.identity.taskID)
        let resolved = try point(matching: persisted)
        let lease = try store.acquireExecution(taskID: resolved.identity.taskID, expected: persisted)
        defer { lease.release() }
        startingPoint = resolved; unconfirmedReplacement = nil
        let identity = resolved.identity, startingDocument = resolved.document, startingDocumentID = resolved.documentID
        func checkLeased() throws {
            try check()
            try lease.assertOwnership()
            try Task.checkCancellation()
        }
        func save(_ status: ComputerUseTaskStepStatus) throws {
            try lease.assertOwnership()
            var next = identity; next.statuses = [status]
            try store.save(next, replacing: persisted)
            persisted = next
        }
        func receipt() -> ComputerUseBrowserDocument? {
            guard let value = browser.receipt(taskID: request.goal.taskID, operationID: operationID),
                  value.taskID == request.goal.taskID, value.operationID == operationID,
                  value.contextID == browser.contextID, value.source == .automationNavigation,
                  value.requestedURL == request.destination else { return nil }
            return value
        }
        try checkLeased()
        if let status = persisted?.statuses.first, status != .planned {
            // Recovery never reaches the native effect API, even when the
            // page is now elsewhere or the file already says verified.
            guard let result = receipt() else {
                if status == .attempted { try save(.uncertain) }
                throw ComputerUseTaskExecutionError.uncertainEffect(operationID)
            }
            if status != .verified { try save(.verified) }
            try checkLeased()
            isPending = false
            return result
        }
        guard !browser.hasNavigationAttempt(operationID: operationID) else { throw ComputerUseTaskExecutionError.uncertainEffect(operationID) }
        if persisted == nil { try save(.planned) }
        do {
            try checkLeased()
            if let startingDocument {
                guard browser.validate(startingDocument) else { throw ComputerUseBrowserError.pageChanged }
                // Query/provider authority comes from the host and full goal,
                // not page controls. Re-read authentication on the same native
                // Document; a refreshed snapshot nonce is not a page change.
                let fresh = try await browser.observePage(document: startingDocument)
                guard fresh.documentID == startingDocumentID else { throw ComputerUseBrowserError.pageChanged }
            }
            else { guard try browser.isUnnavigatedSession(session) else { throw ComputerUseBrowserError.pageChanged } }
            try checkLeased()
            let result = try await browser.navigate(taskID: request.goal.taskID, operationID: operationID,
                to: request.destination, from: startingDocument,
                requiringUnnavigatedSession: startingDocument == nil ? session : nil, willBeginEffect: {
                    try checkLeased()
                    try save(.attempted)
                })
            guard receipt() == result, persisted?.statuses.first == .attempted else {
                throw ComputerUseTaskExecutionError.uncertainEffect(operationID)
            }
            try save(.verified)
            try checkLeased()
            isPending = false
            return result
        } catch {
            // Retain late confirmation without returning success after Pause.
            // A failed write leaves the durable attempt for receipt recovery.
            if persisted?.statuses.first == .attempted { try? save(receipt() == nil ? .uncertain : .verified) }
            throw error
        }
    }

    /// Explicitly refresh only the starting document. Query/provider/goal,
    /// session and operation identity remain fixed, and this never navigates.
    func refreshStartingPage(checkCurrent: () throws -> Void) async throws -> RefreshResult {
        guard !isExecuting else { throw ComputerUseBrowserInitialSearchError.busy }
        guard !isRetired else { throw ComputerUseBrowserInitialSearchError.retired }
        guard isPending else { return .noPendingStage }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw ComputerUseBrowserInitialSearchError.retired }
            try checkCurrent()
            try browser.validateWorkflowSession(session)
        }
        try check()
        let store = try makeStore(directory)
        let persisted = try store.load(taskID: startingPoint.identity.taskID)
        let resolved = try point(matching: persisted)
        let lease = try store.acquireExecution(taskID: resolved.identity.taskID, expected: persisted)
        defer { lease.release() }
        startingPoint = resolved; unconfirmedReplacement = nil
        func checkLeased() throws { try check(); try lease.assertOwnership(); try Task.checkCancellation() }
        try checkLeased()
        guard persisted == nil || persisted?.statuses == [.planned],
              !browser.hasNavigationAttempt(operationID: operationID) else { return .requiresReconciliation }
        let document = try await browser.acquireObservedDocument(taskID: request.goal.taskID)
        try checkLeased()
        let page = try await browser.observePage(document: document)
        try checkLeased()
        guard browser.validate(page.document) else { throw ComputerUseBrowserError.pageChanged }
        guard !browser.hasNavigationAttempt(operationID: operationID) else { return .requiresReconciliation }
        let replacement = Self.startingPoint(request: request, session: session, operationID: operationID, page: page)
        let unchanged = Self.matches(replacement.identity, resolved.identity)
        if unchanged, persisted != nil { return .unchanged }
        unconfirmedReplacement = replacement
        if let persisted { try store.replaceUnattemptedBinding(replacement.identity, replacing: persisted) }
        else { try store.save(replacement.identity, replacing: nil) }
        // A committed refresh remains a fact after a late Pause. Keep its
        // matching document before surfacing cancellation, but never revive
        // a retired owner. Failed writes retain the two known candidates.
        if !isRetired { startingPoint = replacement; unconfirmedReplacement = nil }
        try checkLeased()
        return unchanged ? .unchanged : .updated
    }

    func retire() { isRetired = true }
}

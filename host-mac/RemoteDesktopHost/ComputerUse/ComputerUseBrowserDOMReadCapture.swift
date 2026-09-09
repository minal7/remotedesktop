import Foundation

/// Retains an already dispatched private preparation read independently of
/// its cancelled waiter. Reuse is a historical result, not current-page proof.
@MainActor
final class ComputerUseBrowserDOMReadCapture: CustomStringConvertible {
    private let command: ComputerUseBrowserDOMCommand
    private let document: ComputerUseBrowserDocument
    private var argumentDigest: String?
    private var revisionID: String?
    private var completion: Result<ComputerUseBrowserDOMReply, Error>?
    private var recoveredReply: ComputerUseBrowserDOMReply?
    private(set) var didStart = false

    /// Only the initial field read may establish this absence. A pending
    /// callback, ordinary failure or any recovered result remains retained.
    var initialFieldsWereNotObserved: Bool {
        guard command == .formFields, recoveredReply == nil else { return false }
        if !didStart { return completion == nil }
        guard case .failure(let error)? = completion else { return false }
        return error as? ComputerUseBrowserError == .authenticationRequired
    }

    init(command: ComputerUseBrowserDOMCommand, document: ComputerUseBrowserDocument) throws {
        guard [.formFields, .extendFormFields, .reviseFormFields, .verifyFormState, .bindPageFields, .prepareFormPreservation].contains(command) else {
            throw ComputerUseBrowserError.unsupportedDocument
        }
        self.command = command; self.document = document
    }

    func retainedReply(command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                       document: ComputerUseBrowserDocument?) throws -> ComputerUseBrowserDOMReply? {
        try validate(command: command, arguments: arguments, document: document)
        guard didStart else { return nil }
        guard let completion else { throw ComputerUseBrowserError.busy }
        if let recoveredReply { return recoveredReply }
        // These commands check authentication before any private observation.
        // A verified empty auth reply captured no baseline. A caller still
        // needs current ownership and original-page validation before retrying.
        if case .failure(let error) = completion, error as? ComputerUseBrowserError == .authenticationRequired {
            didStart = false; self.completion = nil
            return nil
        }
        return try completion.get()
    }

    func begin(command: ComputerUseBrowserDOMCommand, arguments: [String: Any], document: ComputerUseBrowserDocument?) throws {
        try validate(command: command, arguments: arguments, document: document)
        guard !didStart else { throw ComputerUseBrowserError.busy }
        argumentDigest = try digest(arguments)
        revisionID = command == .reviseFormFields ? arguments["revisionID"] as? String : nil
        didStart = true
    }

    func finish(_ completion: Result<ComputerUseBrowserDOMReply, Error>) {
        guard didStart, self.completion == nil else { return }
        self.completion = completion
    }

    var needsRevisionReconciliation: Bool {
        guard command == .reviseFormFields, didStart, recoveredReply == nil,
              case .failure(let error)? = completion else { return false }
        return error as? ComputerUseBrowserError != .authenticationRequired
    }

    func requiresRevisionReconciliation(arguments: [String: Any], document: ComputerUseBrowserDocument) throws -> Bool {
        try validate(command: .reviseFormFields, arguments: arguments, document: document)
        return needsRevisionReconciliation
    }

    /// A second, read-only native result can reconcile a terminal callback
    /// error. Keep that error, the attempt ID and the original arguments.
    func reconcileRevision(_ reply: ComputerUseBrowserDOMReply, arguments: [String: Any],
                           document: ComputerUseBrowserDocument, documentID: String, inputLedgerID: String) throws {
        try validate(command: .reviseFormFields, arguments: arguments, document: document)
        guard needsRevisionReconciliation, let revisionID, reply.recoveredRevisionID == revisionID,
              reply.documentID == documentID, reply.inputLedgerID == inputLedgerID,
              reply.status == "ok" || (reply.status == "revision-not-captured" && reply.uncapturedRevisionID == revisionID) else {
            throw ComputerUseBrowserError.pageChanged
        }
        recoveredReply = reply
    }

    /// Preserve the dispatched callback and its exact arguments forever.
    /// Only the adapter's explicit pre-capture rejection permits the owner
    /// to recover an earlier frame; ordinary failures and pending callbacks do not.
    func revisionWasNotCaptured(document: ComputerUseBrowserDocument, documentID: String, inputLedgerID: String) -> Bool {
        guard command == .reviseFormFields, self.document == document, didStart, let revisionID else { return false }
        let reply: ComputerUseBrowserDOMReply
        if let recoveredReply { reply = recoveredReply }
        else if case .success(let original)? = completion { reply = original }
        else { return false }
        return reply.status == "revision-not-captured" && reply.uncapturedRevisionID == revisionID
            && reply.documentID == documentID && reply.inputLedgerID == inputLedgerID
    }

    private func validate(command: ComputerUseBrowserDOMCommand, arguments: [String: Any],
                          document: ComputerUseBrowserDocument?) throws {
        let expected = try digest(arguments)
        guard command == self.command, document == self.document,
              argumentDigest == nil || argumentDigest == expected else { throw ComputerUseBrowserError.pageChanged }
    }

    private func digest(_ arguments: [String: Any]) throws -> String {
        var stable = arguments
        // A fresh nonce may describe the same proven original page after
        // handback. Control IDs, source scope and ledger identity stay exact.
        stable.removeValue(forKey: "snapshotID")
        let data = try JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])
        return ComputerUseTaskContract.digest(["browser-private-preparation-read-v1",String(decoding: data, as: UTF8.self)])
    }

    nonisolated var description: String { "BrowserPrivateReadCapture" }
}

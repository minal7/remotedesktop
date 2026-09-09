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
    private(set) var didStart = false

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

    /// Preserve the dispatched callback and its exact arguments forever.
    /// Only the adapter's explicit pre-capture rejection permits the owner
    /// to recover an earlier frame; ordinary failures and pending callbacks do not.
    func revisionWasNotCaptured(document: ComputerUseBrowserDocument, documentID: String, inputLedgerID: String) -> Bool {
        guard command == .reviseFormFields, self.document == document, didStart,
              let revisionID, case .success(let reply)? = completion else { return false }
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

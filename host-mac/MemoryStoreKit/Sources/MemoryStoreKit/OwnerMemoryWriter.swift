import CryptoKit
import Foundation

public enum OwnerRememberKind: String, Sendable, CaseIterable {
    case profile
    case fact

    fileprivate var storeKind: MemoryKind { self == .profile ? .profile : .fact }
}

public enum OwnerMemoryCandidateOrigin: String, Sendable, CaseIterable {
    case model
    case page
    case tool
}

public struct OwnerMemoryContext: Sendable, Equatable {
    public let ownerID: String
    public let sessionID: String
    public let taskID: String?

    public init(ownerID: String, sessionID: String, taskID: String? = nil) {
        self.ownerID = ownerID
        self.sessionID = sessionID
        self.taskID = taskID
    }
}

public struct OwnerMemoryPolicy: Sendable, Equatable {
    public let featureEnabled: Bool
    public let incognito: Bool
    public let noMemory: Bool
    public let pauseLearning: Bool

    public init(featureEnabled: Bool, incognito: Bool = false, noMemory: Bool = false,
                pauseLearning: Bool = false) {
        self.featureEnabled = featureEnabled
        self.incognito = incognito
        self.noMemory = noMemory
        self.pauseLearning = pauseLearning
    }
}

public struct OwnerMemoryCandidate: Sendable, Equatable {
    public let kind: OwnerRememberKind
    public let text: String
    public let origin: OwnerMemoryCandidateOrigin
    public let sourceReference: String
    public let sourceSpan: String

    public init(kind: OwnerRememberKind, text: String, origin: OwnerMemoryCandidateOrigin,
                sourceReference: String, sourceSpan: String) {
        self.kind = kind
        self.text = text
        self.origin = origin
        self.sourceReference = sourceReference
        self.sourceSpan = sourceSpan
    }
}

public struct OwnerMemoryProposal: Sendable, Equatable {
    public let proposalID: String
    public let kind: OwnerRememberKind
    public let text: String
    public let origin: OwnerMemoryCandidateOrigin
    public let sourceReference: String
    public let sourceSpan: String
    public let expiresAt: Date
}

public struct OwnerMemoryWriteReceipt: Sendable, Equatable {
    public let recordID: String
    public let idempotentRetry: Bool
}

public enum OwnerMemoryWriterError: Error, Equatable {
    case unauthorized
    case inactiveTask
    case disabled
    case incognito
    case noMemory
    case learningPaused
    case invalidInput
    case proposalLimit
    case proposalNotFound
    case proposalExpired
    case proposalBindingMismatch
    case commandConflict
    case recordNotFound
    case storageFailure
    case forgotten
    case forgetReentrant
}

public typealias OwnerMemoryAuthorizer = @Sendable (OwnerMemoryContext) -> Bool
public typealias OwnerTaskLiveness = @Sendable (_ ownerID: String, _ taskID: String) -> Bool
public typealias OwnerMemoryPolicyProvider = @Sendable () -> OwnerMemoryPolicy

/// Isolated write/read service. Authorization closures are only an integration seam until the host
/// supplies its real broker-bound identity and task-liveness checks. `remember` trusts its caller
/// to use a dedicated explicit-memory entry; this type does not classify generic chat, detect
/// secrets, or make arbitrary text safe. Never pass ordinary task prompts or vault values here.
public final class OwnerMemoryWriter: @unchecked Sendable {
    private struct StagedProposal {
        let proposal: OwnerMemoryProposal
        let ownerID: String
        let sessionID: String
        let taskID: String
        let recordID: String
        let statementID: String
        let origin: OwnerMemoryCandidateOrigin
        let sourceReference: String
        let sourceSpan: String
    }

    private let store: MemoryStore
    private let authorize: OwnerMemoryAuthorizer
    private let isTaskActive: OwnerTaskLiveness
    private let policy: OwnerMemoryPolicyProvider
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let lifecycle = NSCondition()
    private let lifecycleThreadKey = "MemoryStoreKit.OwnerMemoryWriter.active.\(UUID().uuidString)"
    private var forgetStarted = false
    private var activeOperations = 0
    private var staged: [String: StagedProposal] = [:]
    private var expiredProposalIDs: Set<String> = []
    private var proposalCountByTask: [String: Int] = [:]

    /// Non-value diagnostic for package tests proving Forget erased staged RAM state.
    var stagedProposalCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return staged.count
    }

    var hasOpenStoreHandleForTesting: Bool { store.hasOpenHandleForTesting }

    var isActiveOnCurrentThread: Bool {
        (Thread.current.threadDictionary[lifecycleThreadKey] as? Int ?? 0) > 0
    }

    public init(store: MemoryStore, authorize: @escaping OwnerMemoryAuthorizer,
                isTaskActive: @escaping OwnerTaskLiveness,
                policy: @escaping OwnerMemoryPolicyProvider,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.authorize = authorize
        self.isTaskActive = isTaskActive
        self.policy = policy
        self.now = now
    }

    /// Accepts only an explicit owner memory command. No source enum or caller-provided lineage is accepted.
    public func remember(kind: OwnerRememberKind, text: String, commandID: String,
                         context: OwnerMemoryContext) throws -> OwnerMemoryWriteReceipt {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireWritablePolicy()
            guard valid(text, maximumBytes: 8_192), valid(commandID, maximumBytes: 128),
                  valid(context.ownerID, maximumBytes: 256), valid(context.sessionID, maximumBytes: 256) else {
                throw OwnerMemoryWriterError.invalidInput
            }
            let digest = payloadDigest(ownerID: context.ownerID, taskID: context.taskID,
                                       kind: kind, text: text, proposalID: nil)
            let key = commandKey(ownerID: context.ownerID, commandID: commandID)
            let record = MemoryRecord(id: UUID().uuidString, kind: kind.storeKind, body: text,
                source: .ownerMessage, observedAt: timestamp(now()), confidence: 1,
                provenance: MemoryProvenance(statementID: UUID().uuidString))
            return try commit(record, key: key, digest: digest)
        }
    }

    /// Revises an existing ordinary owner record without changing its identity or kind.
    public func edit(recordID: String, expectedRevision: String, text: String, commandID: String,
                     context: OwnerMemoryContext) throws -> OwnerMemoryWriteReceipt {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireWritablePolicy()
            guard valid(recordID, maximumBytes: 512), valid(expectedRevision, maximumBytes: 128),
                  expectedRevision.utf8.count == 64,
                  expectedRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  valid(commandID, maximumBytes: 128), validEditText(text),
                  valid(context.ownerID, maximumBytes: 256), valid(context.sessionID, maximumBytes: 256) else {
                throw OwnerMemoryWriterError.invalidInput
            }
            let existing: MemoryRecord?
            do { existing = try store.get(id: recordID) }
            catch { throw OwnerMemoryWriterError.storageFailure }
            if let existing, existing.kind != .profile && existing.kind != .fact {
                throw OwnerMemoryWriterError.invalidInput
            }
            let replacement = MemoryRecord(id: recordID, kind: existing?.kind ?? .fact, body: text,
                source: .ownerMessage, observedAt: timestamp(now()), active: existing?.active ?? true,
                confidence: 1, provenance: MemoryProvenance(statementID: UUID().uuidString))
            let digest = editPayloadDigest(ownerID: context.ownerID, sessionID: context.sessionID,
                taskID: context.taskID, recordID: recordID, expectedRevision: expectedRevision, text: text)
            let key = commandKey(ownerID: context.ownerID, commandID: commandID)
            do {
                let result = try store.commitOwnerEdit(expected: existing,
                    revisionMatches: existing.map(Self.revision(for:)) == expectedRevision,
                    replacement: replacement, commandKey: key, payloadDigest: digest)
                return OwnerMemoryWriteReceipt(recordID: result.recordID, idempotentRetry: result.idempotent)
            } catch MemoryStoreError.commandConflict {
                throw OwnerMemoryWriterError.commandConflict
            } catch MemoryStoreError.recordNotFound {
                throw OwnerMemoryWriterError.recordNotFound
            } catch {
                throw OwnerMemoryWriterError.storageFailure
            }
        }
    }

    /// Opaque digest of every field that can affect an edit's compare-and-swap decision.
    public static func revision(for record: MemoryRecord) -> String {
        var bytes = Data()
        let fields = [record.id, record.kind.rawValue, record.body, record.source.rawValue,
            String(record.observedAt), record.active ? "1" : "0", record.confidence.bitPattern.description,
            record.provenance.sourceMessageID ?? "", record.provenance.proposalID ?? "",
            record.provenance.statementID ?? "", record.provenance.candidateOrigin ?? "",
            record.provenance.sourceReference ?? "", record.provenance.sourceSpan ?? ""]
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Stages model/page/tool material in RAM only. It cannot write a memory record.
    public func stageProposal(candidate: OwnerMemoryCandidate,
                              context: OwnerMemoryContext) throws -> OwnerMemoryProposal {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: true)
            let currentPolicy = try validatedPolicy()
            if currentPolicy.pauseLearning { throw OwnerMemoryWriterError.learningPaused }
            guard let taskID = context.taskID,
                  valid(candidate.text, maximumBytes: 8_192),
                  valid(candidate.sourceReference, maximumBytes: 1_024),
                  valid(candidate.sourceSpan, maximumBytes: 1_024),
                  valid(context.ownerID, maximumBytes: 256), valid(context.sessionID, maximumBytes: 256) else {
                throw OwnerMemoryWriterError.invalidInput
            }
            lock.lock(); defer { lock.unlock() }
            expireProposalsLocked()
            let taskKey = context.ownerID + "/" + taskID
            guard proposalCountByTask[taskKey, default: 0] < 3 else { throw OwnerMemoryWriterError.proposalLimit }
            let proposal = OwnerMemoryProposal(proposalID: UUID().uuidString, kind: candidate.kind,
                text: candidate.text, origin: candidate.origin, sourceReference: candidate.sourceReference,
                sourceSpan: candidate.sourceSpan,
                expiresAt: now().addingTimeInterval(10 * 60))
            staged[proposal.proposalID] = StagedProposal(proposal: proposal, ownerID: context.ownerID,
                sessionID: context.sessionID, taskID: taskID, recordID: UUID().uuidString,
                statementID: UUID().uuidString, origin: candidate.origin,
                sourceReference: candidate.sourceReference, sourceSpan: candidate.sourceSpan)
            proposalCountByTask[taskKey, default: 0] += 1
            return proposal
        }
    }

    /// Confirmation is a separate explicit owner action bound to the exact staged proposal.
    public func confirmProposal(proposalID: String, commandID: String,
                                context: OwnerMemoryContext) throws -> OwnerMemoryWriteReceipt {
        try withActiveOperation {
            try confirmProposalWhileActive(proposalID: proposalID, commandID: commandID, context: context)
        }
    }

    private func confirmProposalWhileActive(proposalID: String, commandID: String,
                                            context: OwnerMemoryContext) throws -> OwnerMemoryWriteReceipt {
        try authorizeOperation(context, requiresTask: true)
        try requireWritablePolicy()
        guard valid(proposalID, maximumBytes: 128), valid(commandID, maximumBytes: 128),
              valid(context.ownerID, maximumBytes: 256), valid(context.sessionID, maximumBytes: 256),
              let taskID = context.taskID else { throw OwnerMemoryWriterError.invalidInput }
        lock.lock()
        defer { lock.unlock() }
        expireProposalsLocked()
        guard let item = staged[proposalID] else {
            do {
                guard let receipt = try store.proposalReceipt(id: proposalID) else {
                    throw expiredProposalIDs.contains(proposalID)
                        ? OwnerMemoryWriterError.proposalExpired : OwnerMemoryWriterError.proposalNotFound
                }
                guard receipt.ownerID == context.ownerID, receipt.sessionID == context.sessionID,
                      receipt.taskID == taskID else { throw OwnerMemoryWriterError.proposalBindingMismatch }
                guard receipt.commandKey == commandKey(ownerID: context.ownerID, commandID: commandID) else {
                    throw OwnerMemoryWriterError.commandConflict
                }
                guard receipt.expiresAt > timestamp(now()) else { throw OwnerMemoryWriterError.proposalExpired }
                guard let saved = try store.get(id: receipt.recordID),
                      saved.provenance.proposalID == proposalID,
                      saved.source == .ownerConfirmed else { throw OwnerMemoryWriterError.proposalNotFound }
                return OwnerMemoryWriteReceipt(recordID: receipt.recordID, idempotentRetry: true)
            } catch let error as OwnerMemoryWriterError {
                throw error
            } catch {
                throw OwnerMemoryWriterError.storageFailure
            }
        }
        guard item.ownerID == context.ownerID, item.sessionID == context.sessionID,
              item.taskID == taskID else { throw OwnerMemoryWriterError.proposalBindingMismatch }
        guard item.proposal.expiresAt > now() else {
            staged.removeValue(forKey: proposalID)
            throw OwnerMemoryWriterError.proposalExpired
        }
        let digest = payloadDigest(ownerID: context.ownerID, taskID: taskID,
            kind: item.proposal.kind, text: item.proposal.text, proposalID: proposalID)
        let key = commandKey(ownerID: context.ownerID, commandID: commandID)
        let record = MemoryRecord(id: item.recordID, kind: item.proposal.kind.storeKind,
            body: item.proposal.text, source: .ownerConfirmed, observedAt: timestamp(now()),
            confidence: 1, provenance: MemoryProvenance(proposalID: proposalID,
                statementID: item.statementID, candidateOrigin: item.origin.rawValue,
                sourceReference: item.sourceReference, sourceSpan: item.sourceSpan))
        let receipt = try commit(record, key: key, digest: digest,
            durableReceipt: (item.ownerID, item.sessionID, item.taskID, timestamp(item.proposal.expiresAt)))
        staged.removeValue(forKey: proposalID)
        return receipt
    }

    public func list(context: OwnerMemoryContext, limit: Int = 200) throws -> [MemoryRecord] {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
            do { return try store.list(includeInactive: true, limit: limit) }
            catch { throw OwnerMemoryWriterError.storageFailure }
        }
    }

    public func ownerRecordsPage(query: String? = nil, afterRecordID: String? = nil,
                                 limit: Int = 20, context: OwnerMemoryContext) throws -> MemoryRecordPage {
        guard (1...32).contains(limit), query.map({ valid($0, maximumBytes: 2_048) }) ?? true,
              afterRecordID.map({ valid($0, maximumBytes: 512) }) ?? true,
              query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw OwnerMemoryWriterError.invalidInput
        }
        return try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
            do {
                var records = try store.ownerRecordsPage(query: query, afterRecordID: afterRecordID, limit: limit)
                let continues = records.count > limit
                if continues { records.removeLast() }
                return MemoryRecordPage(records: records, nextRecordID: continues ? records.last?.id : nil)
            } catch { throw OwnerMemoryWriterError.storageFailure }
        }
    }

    public func search(_ query: String, context: OwnerMemoryContext,
                       limit: Int = 10) throws -> [MemoryMatch] {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
            do { return try store.search(query, limit: limit) }
            catch { throw OwnerMemoryWriterError.storageFailure }
        }
    }

    /// Preflights export without touching storage. The service repeats these checks after it
    /// acquires lifecycle locks and while the operation is counted against Forget.
    func preflightSealedExport(context: OwnerMemoryContext) throws {
        try authorizeOperation(context, requiresTask: false)
        try requireReadablePolicy()
    }

    /// Keeps query, encoding, and sealing inside the writer's existing Forget drain boundary.
    func withSealedExportOperation<T>(context: OwnerMemoryContext,
        _ operation: (_ revalidate: () throws -> OwnerMemoryPolicy) throws -> T) throws -> T {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
            let result = try operation {
                try self.authorizeOperation(context, requiresTask: false)
                try self.requireReadablePolicy()
                return self.policy()
            }
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
            return result
        }
    }

    /// Internal retrieval boundary for the isolated context builder. It deliberately returns
    /// active records only and never exposes vault values or lineage spans to the model context.
    func retrievalSnapshot(query: String, context: OwnerMemoryContext,
                           candidateLimit: Int) throws -> (profiles: [MemoryRecord], candidates: [MemoryRecord], lexical: [MemoryMatch]) {
        try withActiveOperation {
            try retrievalSnapshotWhileActive(query: query, context: context, candidateLimit: candidateLimit)
        }
    }

    private func retrievalSnapshotWhileActive(query: String, context: OwnerMemoryContext,
                           candidateLimit: Int) throws -> (profiles: [MemoryRecord], candidates: [MemoryRecord], lexical: [MemoryMatch]) {
        try validateRetrieval(context)
        guard (1...100).contains(candidateLimit) else { throw OwnerMemoryWriterError.invalidInput }
        do {
            let active = try store.list(includeInactive: false, limit: 500)
            let profiles = active.filter { $0.kind == .profile }
            let candidates = Array(active.filter { $0.kind == .fact || $0.kind == .episode }
                .sorted { $0.observedAt > $1.observedAt }.prefix(candidateLimit))
            var lexicalByID: [String: (match: MemoryMatch, score: Double, bestRank: Int)] = [:]
            let perTermLimit = min(candidateLimit, 50)
            var searches = [query]
            var seenTerms = Set([query.lowercased()])
            for term in Self.literalSearchTerms(query) where seenTerms.insert(term.lowercased()).inserted {
                searches.append(term)
            }
            for term in searches {
                for (rank, match) in try store.search(term, limit: perTermLimit).enumerated() {
                    guard match.record.kind == .fact || match.record.kind == .episode else { continue }
                    let contribution = 1.0 / Double(60 + rank + 1)
                    if let prior = lexicalByID[match.record.id] {
                        lexicalByID[match.record.id] = (match, prior.score + contribution,
                            min(prior.bestRank, rank))
                    } else {
                        lexicalByID[match.record.id] = (match, contribution, rank)
                    }
                }
            }
            let lexical = lexicalByID.values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.bestRank != $1.bestRank { return $0.bestRank < $1.bestRank }
                return $0.match.record.id < $1.match.record.id
            }.prefix(50).map(\.match)
            return (profiles, candidates, Array(lexical))
        } catch let error as OwnerMemoryWriterError {
            throw error
        } catch {
            throw OwnerMemoryWriterError.storageFailure
        }
    }

    /// Recheck authority and policy after each asynchronous retrieval dependency returns.
    func validateRetrieval(_ context: OwnerMemoryContext) throws {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireReadablePolicy()
        }
    }

    func validateRetrievalRecord(_ record: MemoryRecord, context: OwnerMemoryContext) throws {
        try withActiveOperation {
            try validateRetrieval(context)
            do {
                guard let current = try store.get(id: record.id), current.active,
                      current.body == record.body, current.kind == record.kind,
                      current.observedAt == record.observedAt, current.source == record.source,
                      current.confidence == record.confidence,
                      current.provenance == record.provenance else {
                    throw MemoryRetrievalError.staleSnapshot
                }
            } catch let error as MemoryRetrievalError {
                throw error
            } catch {
                throw OwnerMemoryWriterError.storageFailure
            }
        }
    }

    private static func literalSearchTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in query.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                terms.append(String(current))
                current = String.UnicodeScalarView()
                if terms.count == 16 { break }
            }
        }
        if !current.isEmpty, terms.count < 16 { terms.append(String(current)) }
        return terms
    }

    public func delete(recordID: String, context: OwnerMemoryContext) throws {
        try withActiveOperation {
            try authorizeOperation(context, requiresTask: false)
            try requireWritablePolicy()
            guard valid(recordID, maximumBytes: 512) else { throw OwnerMemoryWriterError.invalidInput }
            do { try store.forget(id: recordID) }
            catch { throw OwnerMemoryWriterError.storageFailure }
        }
    }

    /// Runs an exact owner vault operation inside the same lifecycle drain as Forget.
    /// The supplied revalidator is safe to call between Keychain field writes.
    func withVaultEntryOperation<T>(context: OwnerMemoryContext,
                                    _ operation: (_ revalidate: () throws -> Void) throws -> T) throws -> T {
        try withActiveOperation {
            let revalidate = {
                if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
                try self.authorizeOperation(context, requiresTask: false)
                try self.requireWritablePolicy()
                try self.store.requireActive()
            }
            try revalidate()
            let result = try operation(revalidate)
            try revalidate()
            return result
        }
    }

    func withVaultEntryStatus<T>(context: OwnerMemoryContext, _ operation: () throws -> T) throws -> T {
        try withVaultEntryOperation(context: context) { _ in try operation() }
    }

    private func commit(_ record: MemoryRecord, key: String, digest: Data,
                        durableReceipt: (String, String, String, Int64)? = nil) throws -> OwnerMemoryWriteReceipt {
        do {
            let metadata = durableReceipt.map { (ownerID: $0.0, sessionID: $0.1, taskID: $0.2, expiresAt: $0.3) }
            let result = try store.commitOwnerCommand(record, commandKey: key, payloadDigest: digest, receipt: metadata)
            return OwnerMemoryWriteReceipt(recordID: result.recordID, idempotentRetry: result.idempotent)
        } catch MemoryStoreError.commandConflict {
            throw OwnerMemoryWriterError.commandConflict
        } catch {
            throw OwnerMemoryWriterError.storageFailure
        }
    }

    /// Linearizes Forget against all writer operations, including late retrieval revalidation.
    /// Existing operations drain before the caller erases the store; their results are discarded
    /// if the Forget fence won before they completed.
    func beginForget() throws {
        if (Thread.current.threadDictionary[lifecycleThreadKey] as? Int ?? 0) > 0 {
            throw OwnerMemoryWriterError.forgetReentrant
        }
        lifecycle.lock()
        forgetStarted = true
        while activeOperations > 0 { lifecycle.wait() }
        lifecycle.unlock()

        lock.lock()
        staged.removeAll(keepingCapacity: false)
        expiredProposalIDs.removeAll(keepingCapacity: false)
        proposalCountByTask.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func withActiveOperation<T>(_ operation: () throws -> T) throws -> T {
        lifecycle.lock()
        guard !forgetStarted else {
            lifecycle.unlock()
            throw OwnerMemoryWriterError.forgotten
        }
        activeOperations += 1
        lifecycle.unlock()
        enterThreadOperation()

        let result: T
        do {
            try store.requireActive()
            result = try operation()
            // Recheck after every operation so a different service instance's durable Forget
            // fence also discards successful results and late retrieval revalidation.
            try store.requireActive()
        } catch {
            let storeIsFenced: Bool
            do {
                try store.requireActive()
                storeIsFenced = false
            } catch {
                storeIsFenced = true
            }
            let forgetting = finishActiveOperation()
            if forgetting || storeIsFenced { throw OwnerMemoryWriterError.forgotten }
            throw error
        }
        if finishActiveOperation() { throw OwnerMemoryWriterError.forgotten }
        return result
    }

    /// Returns whether Forget began before this operation completed.
    private func finishActiveOperation() -> Bool {
        leaveThreadOperation()
        lifecycle.lock()
        let forgetting = forgetStarted
        activeOperations -= 1
        if activeOperations == 0 { lifecycle.broadcast() }
        lifecycle.unlock()
        return forgetting
    }

    private func enterThreadOperation() {
        let dictionary = Thread.current.threadDictionary
        dictionary[lifecycleThreadKey] = (dictionary[lifecycleThreadKey] as? Int ?? 0) + 1
    }

    private func leaveThreadOperation() {
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[lifecycleThreadKey] as? Int ?? 1) - 1
        if depth > 0 { dictionary[lifecycleThreadKey] = depth }
        else { dictionary.removeObject(forKey: lifecycleThreadKey) }
    }

    private func authorizeOperation(_ context: OwnerMemoryContext, requiresTask: Bool) throws {
        guard authorize(context) else { throw OwnerMemoryWriterError.unauthorized }
        if let taskID = context.taskID {
            guard isTaskActive(context.ownerID, taskID) else { throw OwnerMemoryWriterError.inactiveTask }
        } else if requiresTask {
            throw OwnerMemoryWriterError.inactiveTask
        }
    }

    private func requireWritablePolicy() throws {
        _ = try validatedPolicy()
    }

    private func validatedPolicy() throws -> OwnerMemoryPolicy {
        let current = policy()
        guard current.featureEnabled else { throw OwnerMemoryWriterError.disabled }
        guard !current.incognito else { throw OwnerMemoryWriterError.incognito }
        return current
    }

    private func requireReadablePolicy() throws {
        if try validatedPolicy().noMemory { throw OwnerMemoryWriterError.noMemory }
    }

    private func expireProposalsLocked() {
        let time = now()
        let expired = staged.filter { $0.value.proposal.expiresAt <= time }.map(\.key)
        for id in expired {
            staged.removeValue(forKey: id)
            expiredProposalIDs.insert(id)
        }
        if expiredProposalIDs.count > 256 {
            expiredProposalIDs.removeAll(keepingCapacity: true)
        }
    }

    private func commandKey(ownerID: String, commandID: String) -> String {
        SHA256.hash(data: Data((ownerID + "\u{0}" + commandID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func payloadDigest(ownerID: String, taskID: String?, kind: OwnerRememberKind,
                               text: String, proposalID: String?) -> Data {
        var bytes = Data()
        for value in [ownerID, taskID ?? "", kind.rawValue, text, proposalID ?? ""] {
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return Data(SHA256.hash(data: bytes))
    }

    private func editPayloadDigest(ownerID: String, sessionID: String, taskID: String?,
                                   recordID: String, expectedRevision: String, text: String) -> Data {
        var bytes = Data()
        for value in [ownerID, sessionID, taskID ?? "", "edit", recordID, expectedRevision, text] {
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return Data(SHA256.hash(data: bytes))
    }

    private func timestamp(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        return Int64(max(Double(Int64.min), min(Double(Int64.max), value)))
    }

    private func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.utf8.contains(0)
    }

    private func validEditText(_ value: String) -> Bool {
        guard valid(value, maximumBytes: 4_096), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

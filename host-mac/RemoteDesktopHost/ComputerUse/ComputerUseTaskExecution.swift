import CryptoKit
import Foundation

/// Host-compiled execution contract. Model proposals are not contracts: a
/// capability adapter must bind every entity, operation and predicate before
/// constructing this value. Payloads and observed private values stay in the
/// adapter; this graph contains only identities and digests.
struct ComputerUseTaskContract: Sendable {
    struct Entity: Equatable, Sendable {
        let id: String
        let authorityDigest: String
    }
    struct Predicate: Equatable, Sendable {
        let id: String
        let entityID: String
        let kind: String
        let expectedDigest: String
    }
    struct Operation: Equatable, Sendable {
        let capabilityID: String
        let entityID: String
        let payloadDigest: String
        let payloadVersion: UInt64
    }
    struct Step: Equatable, Sendable {
        let id: String
        let dependencies: [String]
        let operation: Operation
        let preconditions: [String]
        let postconditions: [String]
    }
    let taskID: String
    let promptDigest: String
    let entities: [Entity]
    let predicates: [Predicate]
    let steps: [Step]
    let invariants: [String]
    let outcomes: [String]
    let contractDigest: String

    init(taskID: String, promptDigest: String, entities: [Entity], predicates: [Predicate],
         steps: [Step], invariants: [String], outcomes: [String]) throws {
        func validID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let entityIDs = Set(entities.map(\.id))
        let predicateIDs = Set(predicates.map(\.id))
        let stepIDs = Set(steps.map(\.id))
        func validReferences(_ ids: [String], in known: Set<String>) -> Bool {
            ids.count == Set(ids).count && Set(ids).isSubset(of: known)
        }
        guard validID(taskID), validDigest(promptDigest),
              (1...64).contains(entities.count), entityIDs.count == entities.count,
              (1...256).contains(predicates.count), predicateIDs.count == predicates.count,
              (1...64).contains(steps.count), stepIDs.count == steps.count,
              !outcomes.isEmpty, validReferences(outcomes, in: predicateIDs),
              validReferences(invariants, in: predicateIDs),
              entities.allSatisfy({ validID($0.id) && validDigest($0.authorityDigest) }),
              predicates.allSatisfy({ validID($0.id) && entityIDs.contains($0.entityID)
                  && validID($0.kind) && validDigest($0.expectedDigest) }) else {
            throw ComputerUseTaskExecutionError.invalidContract
        }
        var earlier = Set<String>()
        for step in steps {
            // The compiler supplies a reviewed execution order. Dependencies
            // may form a DAG, but must point backward in that order. A cycle,
            // missing dependency or fabricated target is rejected before input.
            guard validID(step.id), validReferences(step.dependencies, in: earlier),
                  validID(step.operation.capabilityID), entityIDs.contains(step.operation.entityID),
                  validDigest(step.operation.payloadDigest), step.operation.payloadVersion > 0,
                  !step.preconditions.isEmpty, !step.postconditions.isEmpty,
                  validReferences(step.preconditions, in: predicateIDs),
                  validReferences(step.postconditions, in: predicateIDs) else {
                throw ComputerUseTaskExecutionError.invalidContract
            }
            earlier.insert(step.id)
        }
        self.taskID = taskID
        self.promptDigest = promptDigest
        self.entities = entities
        self.predicates = predicates
        self.steps = steps
        self.invariants = invariants
        self.outcomes = outcomes
        var identity = ["computer-use-task-v1", taskID, promptDigest, String(entities.count)]
        for entity in entities { identity += [entity.id, entity.authorityDigest] }
        identity.append(String(predicates.count))
        for predicate in predicates { identity += [predicate.id, predicate.entityID, predicate.kind, predicate.expectedDigest] }
        identity.append(String(steps.count))
        for step in steps {
            identity += [step.id, String(step.dependencies.count)] + step.dependencies
            identity += [step.operation.capabilityID, step.operation.entityID, step.operation.payloadDigest,
                         String(step.operation.payloadVersion), String(step.preconditions.count)] + step.preconditions
            identity += [String(step.postconditions.count)] + step.postconditions
        }
        identity += [String(invariants.count)] + invariants + [String(outcomes.count)] + outcomes
        contractDigest = Self.digest(identity)
    }

    /// A new step can repeat the exact operation on the exact target. Retrying
    /// the same step keeps its identity and must reconcile its durable attempt.
    func effectIdentity(for step: Step) -> String {
        Self.digest(["computer-use-effect-v1", taskID, step.id, step.operation.entityID,
                     step.operation.capabilityID, step.operation.payloadDigest, String(step.operation.payloadVersion)])
    }

    static func digest(_ parts: [String]) -> String {
        var hash = SHA256()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ComputerUseTaskStepStatus: String, Codable, Sendable { case planned, attempted, verified, uncertain }

struct ComputerUseTaskJournal: Codable, Equatable, Sendable {
    typealias Status = ComputerUseTaskStepStatus
    let taskID: String
    let promptDigest: String
    let contractDigest: String
    let stepIDs: [String]
    var statuses: [ComputerUseTaskStepStatus]
}

enum ComputerUseTaskExecutionError: Error, Equatable {
    case invalidContract, journalMismatch, alreadyExecuting
    case preconditionFailed(String), uncertainEffect(String), incompleteOutcome(String)
}

/// Shared transaction engine, independent of the planner and effect adapter.
/// Every effect is durably attempted before dispatch. Only a fresh observation
/// from the adapter can establish its postconditions; effect-return/model prose
/// cannot. Uncertain attempts never gain automatic retry authority.
@MainActor
final class ComputerUseTaskExecution {
    let contract: ComputerUseTaskContract
    private(set) var journal: ComputerUseTaskJournal
    private let predicates: [String: ComputerUseTaskContract.Predicate]
    private let observe: (ComputerUseTaskContract.Predicate) async throws -> Bool
    private let perform: (ComputerUseTaskContract.Step, String) async throws -> Void
    private let persist: (ComputerUseTaskJournal) throws -> Void
    private let assertOwnership: () throws -> Void
    private var isExecuting = false

    init(contract: ComputerUseTaskContract, recovered: ComputerUseTaskJournal? = nil,
         observe: @escaping (ComputerUseTaskContract.Predicate) async throws -> Bool,
         perform: @escaping (ComputerUseTaskContract.Step, String) async throws -> Void,
         persist: @escaping (ComputerUseTaskJournal) throws -> Void,
         assertOwnership: @escaping () throws -> Void) throws {
        self.contract = contract
        let initial = ComputerUseTaskJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id),
            statuses: contract.steps.map { _ in .planned })
        if let recovered {
            guard recovered.taskID == initial.taskID, recovered.promptDigest == initial.promptDigest,
                  recovered.contractDigest == initial.contractDigest, recovered.stepIDs == initial.stepIDs,
                  recovered.statuses.count == initial.statuses.count else {
                throw ComputerUseTaskExecutionError.journalMismatch
            }
            // A sequential dispatcher can persist only a verified prefix,
            // at most one attempted/uncertain step, and a planned suffix.
            var sawUnverified = false
            for status in recovered.statuses {
                if sawUnverified && status != .planned { throw ComputerUseTaskExecutionError.journalMismatch }
                if status != .verified { sawUnverified = true }
            }
        }
        journal = recovered ?? initial
        predicates = Dictionary(uniqueKeysWithValues: contract.predicates.map { ($0.id, $0) })
        self.observe = observe
        self.perform = perform
        self.persist = persist
        self.assertOwnership = assertOwnership
    }

    func run(progress: (Int, Int) -> Void = { _, _ in }) async throws {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        for (index, step) in contract.steps.enumerated() {
            await Task.yield()
            try checkOwnership()
            if journal.statuses[index] == .verified { continue }
            for dependency in step.dependencies {
                guard let position = journal.stepIDs.firstIndex(of: dependency), journal.statuses[position] == .verified else {
                    throw ComputerUseTaskExecutionError.journalMismatch
                }
            }
            for invariant in contract.invariants {
                guard try await satisfies(invariant) else { throw ComputerUseTaskExecutionError.incompleteOutcome(invariant) }
            }
            if journal.statuses[index] != .planned {
                for predicate in step.postconditions {
                    guard try await satisfies(predicate) else {
                        try transition(index, to: .uncertain)
                        throw ComputerUseTaskExecutionError.uncertainEffect(step.id)
                    }
                }
                try transition(index, to: .verified)
                continue
            }
            for predicate in step.preconditions {
                guard try await satisfies(predicate) else { throw ComputerUseTaskExecutionError.preconditionFailed(predicate) }
            }
            try transition(index, to: .attempted)
            do {
                try checkOwnership()
                try await perform(step, contract.effectIdentity(for: step))
                try checkOwnership()
                for predicate in step.postconditions {
                    guard try await satisfies(predicate) else { throw ComputerUseTaskExecutionError.uncertainEffect(step.id) }
                }
                try transition(index, to: .verified)
                progress(index + 1, contract.steps.count)
            } catch {
                if !(error is CancellationError) { try? transition(index, to: .uncertain) }
                throw error
            }
        }
        try checkOwnership()
        for predicate in contract.invariants + contract.outcomes {
            guard try await satisfies(predicate) else { throw ComputerUseTaskExecutionError.incompleteOutcome(predicate) }
        }
        try checkOwnership()
    }

    private func checkOwnership() throws { try Task.checkCancellation(); try assertOwnership() }
    private func satisfies(_ id: String) async throws -> Bool {
        try checkOwnership()
        guard let predicate = predicates[id] else { throw ComputerUseTaskExecutionError.invalidContract }
        let result = try await observe(predicate)
        try checkOwnership()
        return result
    }
    private func transition(_ index: Int, to status: ComputerUseTaskStepStatus) throws {
        var next = journal
        next.statuses[index] = status
        try persist(next)
        journal = next
    }
}

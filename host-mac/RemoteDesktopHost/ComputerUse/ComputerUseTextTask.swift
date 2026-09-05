import Foundation
import CryptoKit

struct ComputerUseTextField: Equatable, Sendable {
    let label: String
    let snapshot: ComputerUseTextSnapshot
}

struct ComputerUseTextPlanEdit: Equatable, Sendable {
    let targetID: String
    let mode: ComputerUseTextEditMode
    let text: String
}

/// A bounded task contract for exact edits in one already-open form. Payloads
/// and values remain host-owned; the journal contains only IDs and statuses.
struct ComputerUseTextTaskContract: Sendable {
    struct Step: Sendable {
        let id: String
        let dependency: String?
        let targetID: String
        let mode: ComputerUseTextEditMode
        let payload: String
        let before: String
        let insertionSelection: NSRange?
        let after: String
        let copySource: ComputerUseTextSnapshot?
    }
    let taskID: String
    let promptDigest: String
    let steps: [Step]
    let finalValues: [String: String]
    let unchangedValues: [String: String]
    let contractDigest: String

    init(taskID: String, prompt: String, fields: [ComputerUseTextField], edits: [ComputerUseTextPlanEdit],
         unchangedTargetIDs: [String] = []) throws {
        try self.init(taskID: taskID, prompt: prompt, fields: fields, operations: edits.map(ComputerUseTextGoalOperation.enterText),
                      unchangedTargetIDs: unchangedTargetIDs)
    }

    init(taskID: String, prompt: String, fields: [ComputerUseTextField], operations: [ComputerUseTextGoalOperation],
         unchangedTargetIDs: [String] = []) throws {
        guard !taskID.isEmpty, (1...8).contains(operations.count),
              Set(fields.map { $0.snapshot.targetID }).count == fields.count,
              Set(unchangedTargetIDs).isSubset(of: Set(fields.map { $0.snapshot.targetID })),
              Set(unchangedTargetIDs).isDisjoint(with: Set(operations.map(\.targetID))) else {
            throw ComputerUseTextTaskError.invalidPlan
        }
        self.taskID = taskID
        self.promptDigest = Self.digest(prompt)
        var values = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var steps: [Step] = []
        let unchanged = Dictionary(uniqueKeysWithValues: fields.filter {
            unchangedTargetIDs.contains($0.snapshot.targetID)
        }.map { ($0.snapshot.targetID, $0.snapshot.value) })
        var finalValues = unchanged
        self.unchangedValues = unchanged
        for (index, operation) in operations.enumerated() {
            let edit: ComputerUseTextPlanEdit
            let source: ComputerUseTextSnapshot?
            switch operation {
            case .enterText(let literal): edit = literal; source = nil
            case .copyField(let sourceTargetID, let targetID, let mode):
                guard let observed = values[sourceTargetID], observed.isEditable, !observed.isSecure else {
                    throw ComputerUseTextTaskError.invalidPlan
                }
                source = observed
                edit = .init(targetID: targetID, mode: mode, text: observed.value)
            }
            guard let field = values[edit.targetID], field.isEditable, !field.isSecure,
                  edit.text.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else {
                throw ComputerUseTextTaskError.invalidPlan
            }
            let range: NSRange
            switch edit.mode {
            case .insert: range = field.selection
            case .replaceAll: range = NSRange(location: 0, length: field.value.utf16.count)
            case .append: range = NSRange(location: field.value.utf16.count, length: 0)
            }
            guard let stringRange = Range(range, in: field.value) else {
                throw ComputerUseTextTaskError.invalidPlan
            }
            let after = field.value.replacingCharacters(in: stringRange, with: edit.text)
            guard after.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else {
                throw ComputerUseTextTaskError.invalidPlan
            }
            // Step index distinguishes legitimate repeated operations even when
            // target, operation and payload are identical. No history strings.
            var identity = [taskID, String(index), field.targetID, edit.mode.rawValue,
                edit.text, field.value, String(range.location), String(range.length), after]
            if let source { identity += ["copied-field-v1", source.targetID, source.value] }
            let id = Self.framedDigest(identity)
            steps.append(Step(id: id, dependency: steps.last?.id,
                              targetID: field.targetID, mode: edit.mode, payload: edit.text,
                              before: field.value,
                              insertionSelection: edit.mode == .insert ? range : nil, after: after, copySource: source))
            values[field.targetID] = ComputerUseTextSnapshot(
                targetID: field.targetID, value: after,
                selection: field.selection.location == NSNotFound ? field.selection
                    : NSRange(location: range.location + edit.text.utf16.count, length: 0),
                isEditable: true, isSecure: false)
            finalValues[field.targetID] = after
        }
        self.steps = steps
        self.finalValues = finalValues
        // Recovery must bind the complete reviewed contract, including fields
        // that must stay unchanged. Matching only prompt and edit IDs would
        // allow a rebuilt plan to silently lose constraints or preconditions.
        var identity = ["text-task-v1", taskID, self.promptDigest, String(steps.count)]
        identity.append(contentsOf: steps.map(\.id))
        identity.append(String(unchanged.count))
        for id in unchanged.keys.sorted() {
            identity.append(id)
            identity.append(unchanged[id]!)
        }
        self.contractDigest = Self.framedDigest(identity)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func framedDigest(_ values: [String]) -> String {
        var hash = SHA256()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ComputerUseTextTaskError: Error, Equatable {
    case invalidPlan, staleTarget, uncertainEffect, incompleteOutcome, journalMismatch
}

typealias ComputerUseTextStepJournal = ComputerUseTaskJournal

/// Text capability compiler/adapter for the shared transaction engine. The
/// existing private journal format remains compatible; its contract digest
/// already covers all exact values, selections, constraints and ordered steps.
@MainActor
final class ComputerUseTextTask {
    let contract: ComputerUseTextTaskContract
    private let execution: ComputerUseTaskExecution
    private let retainedPredicateIDs: Set<String>
    var journal: ComputerUseTextStepJournal {
        Self.textJournal(execution.journal, contract: contract)
    }

    private enum Check {
        case value(String)
        case selection(NSRange)
    }

    init(contract: ComputerUseTextTaskContract,
         recovered: ComputerUseTextStepJournal? = nil,
         read: @escaping (String) async throws -> ComputerUseTextSnapshot?,
         apply: @escaping (ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void,
         applyWithIdentity: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot, String) async throws -> Void)? = nil,
         applyCopyWithIdentity: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot, ComputerUseTextSnapshot, String) async throws -> Void)? = nil,
         persist: @escaping (ComputerUseTextStepJournal) throws -> Void,
         mayAct: @escaping () -> Bool) throws {
        self.contract = contract
        var predicates: [ComputerUseTaskContract.Predicate] = []
        var checks: [String: Check] = [:]
        var retained = Set<String>()
        func predicate(_ id: String, target: String, check: Check) -> String {
            let kind: String
            let digest: String
            switch check {
            case .value(let value):
                kind = "editable-text-value"
                digest = ComputerUseTextTaskContract.digest(value)
            case .selection(let range):
                kind = "editable-text-selection"
                digest = ComputerUseTaskContract.digest([String(range.location), String(range.length)])
            }
            predicates.append(.init(id: id, entityID: target, kind: kind, expectedDigest: digest))
            checks[id] = check
            return id
        }
        let invariants = contract.unchangedValues.keys.sorted().enumerated().map { index, id in
            predicate("constraint-\(index)", target: id, check: .value(contract.unchangedValues[id]!))
        }
        var completedValues: [String: String] = [:]
        var steps: [ComputerUseTaskContract.Step] = []
        for (index, step) in contract.steps.enumerated() {
            var preconditions = [predicate("before-\(index)", target: step.targetID, check: .value(step.before))]
            if let selection = step.insertionSelection {
                preconditions.append(predicate("selection-\(index)", target: step.targetID, check: .selection(selection)))
            }
            var sourcePostconditions: [String] = []
            if let source = step.copySource {
                preconditions.append(predicate("copy-source-before-\(index)", target: source.targetID, check: .value(source.value)))
                if source.targetID != step.targetID {
                    sourcePostconditions.append(predicate("copy-source-after-\(index)", target: source.targetID, check: .value(source.value)))
                }
            }
            for (position, target) in completedValues.keys.sorted().enumerated() {
                let id = predicate("retained-\(index)-\(position)", target: target, check: .value(completedValues[target]!))
                retained.insert(id)
                preconditions.append(id)
            }
            let after = predicate("after-\(index)", target: step.targetID, check: .value(step.after))
            steps.append(.init(id: step.id, dependencies: step.dependency.map { [$0] } ?? [],
                operation: .init(capabilityID: (step.copySource == nil ? "text.edit." : "text.copy.") + step.mode.rawValue, entityID: step.targetID,
                    payloadDigest: ComputerUseTextTaskContract.digest(step.payload), payloadVersion: 1),
                preconditions: preconditions, postconditions: [after] + sourcePostconditions))
            completedValues[step.targetID] = step.after
        }
        let outcomes = contract.finalValues.keys.sorted().enumerated().map { index, id in
            predicate("outcome-\(index)", target: id, check: .value(contract.finalValues[id]!))
        }
        let entities = Set(predicates.map(\.entityID)).sorted().map {
            ComputerUseTaskContract.Entity(id: $0, authorityDigest: ComputerUseTaskContract.digest(["retained-text-reference", $0]))
        }
        let compiled = try ComputerUseTaskContract(taskID: contract.taskID, promptDigest: contract.promptDigest,
            entities: entities, predicates: predicates, steps: steps, invariants: invariants, outcomes: outcomes)
        self.retainedPredicateIDs = retained
        var recoveredExecution: ComputerUseTaskJournal?
        if let recovered {
            guard recovered.taskID == contract.taskID, recovered.promptDigest == contract.promptDigest,
                  recovered.contractDigest == contract.contractDigest, recovered.stepIDs == contract.steps.map(\.id) else {
                throw ComputerUseTextTaskError.journalMismatch
            }
            recoveredExecution = ComputerUseTaskJournal(taskID: recovered.taskID, promptDigest: recovered.promptDigest,
                contractDigest: compiled.contractDigest, stepIDs: recovered.stepIDs, statuses: recovered.statuses)
        }
        let compiledChecks = checks
        let edits = Dictionary(uniqueKeysWithValues: contract.steps.map { ($0.id, $0) })
        do {
            execution = try ComputerUseTaskExecution(contract: compiled, recovered: recoveredExecution,
                observe: { predicate in
                    guard let snapshot = try await read(predicate.entityID), snapshot.targetID == predicate.entityID,
                          snapshot.isEditable, !snapshot.isSecure, let check = compiledChecks[predicate.id] else { return false }
                    switch check {
                    case .value(let value): return snapshot.value.utf8.elementsEqual(value.utf8)
                    case .selection(let selection): return snapshot.selection == selection
                    }
                }, perform: { step, operationID in
                    guard let edit = edits[step.id], let current = try await read(edit.targetID), current.targetID == edit.targetID,
                          current.isEditable, !current.isSecure,
                          current.value.utf8.elementsEqual(edit.before.utf8),
                          edit.insertionSelection.map({ $0 == current.selection }) ?? true else {
                        throw ComputerUseTextTaskError.staleTarget
                    }
                    try Task.checkCancellation()
                    guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                    let plan = ComputerUseTextPlanEdit(targetID: edit.targetID, mode: edit.mode, text: edit.payload)
                    if let source = edit.copySource {
                        guard let fresh = try await read(source.targetID), fresh.targetID == source.targetID,
                              fresh.isEditable, !fresh.isSecure, fresh.value.utf8.elementsEqual(source.value.utf8) else {
                            throw ComputerUseTextTaskError.staleTarget
                        }
                        try Task.checkCancellation()
                        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                        if let applyCopyWithIdentity { try await applyCopyWithIdentity(plan, current, source, operationID) }
                        else { try await apply(plan, current) }
                    } else if let applyWithIdentity { try await applyWithIdentity(plan, current, operationID) }
                    else { try await apply(plan, current) }
                }, persist: { try persist(Self.textJournal($0, contract: contract)) },
                assertOwnership: { guard mayAct() else { throw ComputerUseTextEditError.interrupted } })
        } catch ComputerUseTaskExecutionError.journalMismatch {
            throw ComputerUseTextTaskError.journalMismatch
        }
    }

    func run(progress: (Int, Int) -> Void = { _, _ in }) async throws {
        do { try await execution.run(progress: progress) }
        catch let error as ComputerUseTaskExecutionError {
            switch error {
            case .preconditionFailed(let id):
                throw retainedPredicateIDs.contains(id) ? ComputerUseTextTaskError.incompleteOutcome : .staleTarget
            case .uncertainEffect: throw ComputerUseTextTaskError.uncertainEffect
            case .incompleteOutcome: throw ComputerUseTextTaskError.incompleteOutcome
            case .journalMismatch: throw ComputerUseTextTaskError.journalMismatch
            case .invalidContract: throw ComputerUseTextTaskError.invalidPlan
            case .alreadyExecuting: throw error
            }
        }
    }

    private static func textJournal(_ journal: ComputerUseTaskJournal,
                                    contract: ComputerUseTextTaskContract) -> ComputerUseTextStepJournal {
        ComputerUseTextStepJournal(taskID: journal.taskID, promptDigest: journal.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: journal.stepIDs, statuses: journal.statuses)
    }
}

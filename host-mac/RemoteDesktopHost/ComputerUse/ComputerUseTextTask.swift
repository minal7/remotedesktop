import Foundation
import CryptoKit

struct ComputerUseTextField: Equatable, Sendable {
    struct Choice: Decodable, Equatable, Sendable {
        let id: String
        let label: String
        let disabled: Bool
        let hidden: Bool
    }
    let label: String
    let snapshot: ComputerUseTextSnapshot
    /// A single-choice field stores an opaque selected-option ID (or "" for
    /// no selection) in its private snapshot. Labels are proposal data only.
    let choices: [Choice]?

    init(label: String, snapshot: ComputerUseTextSnapshot, choices: [Choice]? = nil) {
        self.label = label; self.snapshot = snapshot; self.choices = choices
    }
}

struct ComputerUseTextPlanEdit: Equatable, Sendable {
    let targetID: String
    let mode: ComputerUseTextEditMode
    let text: String
}

/// Exact host-owned authority carried to the adapter's input boundary. Copies
/// and literals use the same dispatch path so neither can drop other fields'
/// constraints. The operation ID belongs to the shared transaction engine.
struct ComputerUseTextInputDispatch: Sendable {
    let edit: ComputerUseTextPlanEdit
    let expected: ComputerUseTextSnapshot
    let operationID: String
    let copySource: ComputerUseTextSnapshot?
    let requiredValues: [String: String]
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
        let isChoiceSelection: Bool
        /// Explicit unchanged fields and the latest value of earlier edits.
        /// Destination and copy-source preconditions are carried separately.
        let requiredValues: [String: String]
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
        let catalog = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0) })
        for field in fields {
            if let choices = field.choices {
                guard choices.count <= 64, Set(choices.map(\.id)).count == choices.count,
                      choices.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 64 && $0.label.utf8.count <= 512 }),
                      field.snapshot.value.isEmpty || choices.contains(where: { $0.id == field.snapshot.value }),
                      field.snapshot.selection == NSRange(location: NSNotFound, length: 0) else { throw ComputerUseTextTaskError.invalidPlan }
            }
        }
        var values = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var steps: [Step] = []
        let unchanged = Dictionary(uniqueKeysWithValues: fields.filter {
            unchangedTargetIDs.contains($0.snapshot.targetID)
        }.map { ($0.snapshot.targetID, $0.snapshot.value) })
        var finalValues = unchanged
        self.unchangedValues = unchanged
        for (index, operation) in operations.enumerated() {
            var edit: ComputerUseTextPlanEdit
            let source: ComputerUseTextSnapshot?
            switch operation {
            case .enterText(let literal): edit = literal; source = nil
            case .copyField(let sourceTargetID, let targetID, let mode):
                guard let observed = values[sourceTargetID], observed.isEditable, !observed.isSecure else {
                    throw ComputerUseTextTaskError.invalidPlan
                }
                source = observed
                // Copy the displayed choice label, never a submission token or
                // opaque option ID, while retaining exact source-ID authority.
                let text: String
                if let choices = catalog[sourceTargetID]?.choices {
                    if observed.value.isEmpty { text = "" }
                    else if let choice = choices.first(where: { $0.id == observed.value }) { text = choice.label }
                    else { throw ComputerUseTextTaskError.invalidPlan }
                } else { text = observed.value }
                edit = .init(targetID: targetID, mode: mode, text: text)
            }
            guard let field = values[edit.targetID], field.isEditable, !field.isSecure,
                  edit.text.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else {
                throw ComputerUseTextTaskError.invalidPlan
            }
            let isChoiceSelection = catalog[edit.targetID]?.choices != nil
            if let choices = catalog[edit.targetID]?.choices {
                guard edit.mode == .replaceAll else { throw ComputerUseTextEditError.valueNotRepresentable }
                let matches = choices.filter { !$0.disabled && !$0.hidden && $0.label.utf8.elementsEqual(edit.text.utf8) }
                guard matches.count == 1, let choice = matches.first else { throw ComputerUseTextEditError.valueNotRepresentable }
                edit = .init(targetID: edit.targetID, mode: .replaceAll, text: choice.id)
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
            let requiredValues = finalValues
            var identity = ["text-input-required-values-v3", taskID, String(index), field.targetID, edit.mode.rawValue,
                edit.text, field.value, String(range.location), String(range.length), after]
            if let source { identity += ["copied-field-v2-dispatch-required", source.targetID, source.value] }
            if isChoiceSelection { identity.append("native-single-choice-v1") }
            if let source, catalog[source.targetID]?.choices != nil { identity.append("copy-displayed-choice-label-v1") }
            identity.append(String(requiredValues.count))
            for targetID in requiredValues.keys.sorted() {
                identity += [targetID, requiredValues[targetID]!]
            }
            let id = Self.framedDigest(identity)
            steps.append(Step(id: id, dependency: steps.last?.id,
                              targetID: field.targetID, mode: edit.mode, payload: edit.text,
                              before: field.value,
                              insertionSelection: edit.mode == .insert ? range : nil, after: after, copySource: source,
                              isChoiceSelection: isChoiceSelection,
                              requiredValues: requiredValues))
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

/// Requirements retained from a completed edit transaction, not proof that
/// the page still satisfies them. A continuation must freshly check both the
/// exact final values and the original adapter-owned dispatch receipts.
struct ComputerUseTextTaskContinuation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    let promptDigest: String
    let contractDigest: String
    let finalValues: [String: String]
    let editedTargetIDs: Set<String>
    let inputOperationIDs: [String]
    let digest: String

    fileprivate init(contract: ComputerUseTextTaskContract, inputOperationIDs: [String]) {
        taskID = contract.taskID; promptDigest = contract.promptDigest; contractDigest = contract.contractDigest
        let finalValues = contract.finalValues, editedTargetIDs = Set(contract.steps.map(\.targetID))
        self.finalValues = finalValues; self.editedTargetIDs = editedTargetIDs
        self.inputOperationIDs = inputOperationIDs
        digest = ComputerUseTaskContract.digest(["verified-text-continuation-v1", taskID, promptDigest, contractDigest,
            String(inputOperationIDs.count)] + inputOperationIDs + [String(finalValues.count)]
            + finalValues.keys.sorted().flatMap { [$0, finalValues[$0]!, editedTargetIDs.contains($0) ? "edited" : "unchanged"] })
    }

    var description: String { "VerifiedTextContinuationRequirements" }
    var debugDescription: String { description }
}

/// Text capability compiler/adapter for the shared transaction engine. The
/// private journal format is unchanged, but the versioned step identities
/// reject older contracts that did not bind dispatch evidence and retained
/// value requirements to every input step.
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
        case inputReceipt(Int)
    }

    init(contract: ComputerUseTextTaskContract,
         recovered: ComputerUseTextStepJournal? = nil,
         read: @escaping (String) async throws -> ComputerUseTextSnapshot?,
         apply: @escaping (ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void,
         applyWithIdentity: ((ComputerUseTextInputDispatch) async throws -> Void)? = nil,
         didDispatchInput: ((String) async throws -> Bool)? = nil,
         persist: @escaping (ComputerUseTextStepJournal) throws -> Void,
         acquireExecutionLease: (() throws -> any ComputerUseTaskExecutionLease)? = nil,
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
            case .inputReceipt(let index):
                kind = "text-input-dispatched"
                digest = contract.steps[index].id
            }
            predicates.append(.init(id: id, entityID: target, kind: kind, expectedDigest: digest))
            checks[id] = check
            return id
        }
        let invariants = contract.unchangedValues.keys.sorted().enumerated().map { index, id in
            predicate("constraint-\(index)", target: id, check: .value(contract.unchangedValues[id]!))
        }
        var completedValues: [String: String] = [:]
        var inputReceipts: [String] = []
        var steps: [ComputerUseTaskContract.Step] = []
        for (index, step) in contract.steps.enumerated() {
            var preconditions = [predicate("before-\(index)", target: step.targetID, check: .value(step.before))]
            for receipt in inputReceipts { retained.insert(receipt); preconditions.append(receipt) }
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
            let receipt = predicate("input-dispatched-\(index)", target: step.targetID, check: .inputReceipt(index))
            inputReceipts.append(receipt)
            for (position, target) in completedValues.keys.sorted().enumerated() {
                let id = predicate("retained-\(index)-\(position)", target: target, check: .value(completedValues[target]!))
                retained.insert(id)
                preconditions.append(id)
            }
            let after = predicate("after-\(index)", target: step.targetID, check: .value(step.after))
            steps.append(.init(id: step.id, dependencies: step.dependency.map { [$0] } ?? [],
                operation: .init(capabilityID: step.isChoiceSelection ? "browser.choice.select"
                    : (step.copySource == nil ? "text.edit." : "text.copy.") + step.mode.rawValue, entityID: step.targetID,
                    payloadDigest: ComputerUseTextTaskContract.digest(step.payload), payloadVersion: 1),
                preconditions: preconditions, postconditions: [after, receipt] + sourcePostconditions))
            completedValues[step.targetID] = step.after
        }
        let outcomes = contract.finalValues.keys.sorted().enumerated().map { index, id in
            predicate("outcome-\(index)", target: id, check: .value(contract.finalValues[id]!))
        }
        let entities = Set(predicates.map(\.entityID)).sorted().map {
            ComputerUseTaskContract.Entity(id: $0, authorityDigest: ComputerUseTaskContract.digest(["retained-text-reference", $0]))
        }
        let compiled = try ComputerUseTaskContract(taskID: contract.taskID, promptDigest: contract.promptDigest,
            entities: entities, predicates: predicates, steps: steps, invariants: invariants, outcomes: outcomes + inputReceipts)
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
        let operationIDs = compiled.steps.map { compiled.effectIdentity(for: $0) }
        // Without a document-owned receipt, only a completed adapter call in
        // this live task proves dispatch. A rebuilt task must remain uncertain
        // even if the field already matches or somebody else changed it to
        // the expected value. A successful adapter return is required to
        // mean its input operation completed; an empty fallback is not input.
        var locallyDispatchedInputs = Set<String>()
        do {
            execution = try ComputerUseTaskExecution(contract: compiled, recovered: recoveredExecution,
                observe: { predicate in
                    guard let snapshot = try await read(predicate.entityID), snapshot.targetID == predicate.entityID,
                          snapshot.isEditable, !snapshot.isSecure, let check = compiledChecks[predicate.id] else { return false }
                    switch check {
                    case .value(let value): return snapshot.value.utf8.elementsEqual(value.utf8)
                    case .selection(let selection): return snapshot.selection == selection
                    case .inputReceipt(let index):
                        if let didDispatchInput { return try await didDispatchInput(operationIDs[index]) }
                        return locallyDispatchedInputs.contains(operationIDs[index])
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
                    }
                    // The durable attempt and the last asynchronous reads can
                    // outlive the engine's preflight. Recheck retained values
                    // before either adapter, and carry the same requirements
                    // into the browser's synchronous check-and-edit operation.
                    for targetID in edit.requiredValues.keys.sorted() {
                        try Task.checkCancellation()
                        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                        let retained = try await read(targetID)
                        try Task.checkCancellation()
                        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                        guard let retained, retained.targetID == targetID, retained.isEditable, !retained.isSecure,
                              retained.value.utf8.elementsEqual(edit.requiredValues[targetID]!.utf8) else {
                            throw ComputerUseTextTaskError.incompleteOutcome
                        }
                    }
                    if let applyWithIdentity {
                        try await applyWithIdentity(.init(edit: plan, expected: current, operationID: operationID,
                            copySource: edit.copySource, requiredValues: edit.requiredValues))
                    } else { try await apply(plan, current) }
                    locallyDispatchedInputs.insert(operationID)
                }, persist: { try persist(Self.textJournal($0, contract: contract)) },
                acquireExecutionLease: acquireExecutionLease,
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

    /// Never runs or retries unfinished edits to obtain continuation authority.
    /// Recovered verified flags alone cannot prove a live browser receipt.
    func verifiedContinuation() throws -> ComputerUseTextTaskContinuation {
        guard execution.journal.statuses.count == contract.steps.count,
              execution.journal.statuses.allSatisfy({ $0 == .verified }) else {
            throw ComputerUseTextTaskError.incompleteOutcome
        }
        return .init(contract: contract, inputOperationIDs: execution.contract.steps.map {
            execution.contract.effectIdentity(for: $0)
        })
    }

    private static func textJournal(_ journal: ComputerUseTaskJournal,
                                    contract: ComputerUseTextTaskContract) -> ComputerUseTextStepJournal {
        ComputerUseTextStepJournal(taskID: journal.taskID, promptDigest: journal.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: journal.stepIDs, statuses: journal.statuses)
    }
}

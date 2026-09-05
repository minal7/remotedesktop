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
    }
    let taskID: String
    let promptDigest: String
    let steps: [Step]
    let finalValues: [String: String]

    init(taskID: String, prompt: String, fields: [ComputerUseTextField], edits: [ComputerUseTextPlanEdit]) throws {
        guard !taskID.isEmpty, (1...8).contains(edits.count),
              Set(fields.map { $0.snapshot.targetID }).count == fields.count else {
            throw ComputerUseTextTaskError.invalidPlan
        }
        self.taskID = taskID
        self.promptDigest = Self.digest(prompt)
        var values = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var steps: [Step] = []
        var finalValues: [String: String] = [:]
        for (index, edit) in edits.enumerated() {
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
            let id = Self.digest([taskID, String(index), field.targetID, edit.mode.rawValue,
                                  Self.digest(edit.text)].joined(separator: ":"))
            steps.append(Step(id: id, dependency: steps.last?.id,
                              targetID: field.targetID, mode: edit.mode, payload: edit.text,
                              before: field.value,
                              insertionSelection: edit.mode == .insert ? range : nil, after: after))
            values[field.targetID] = ComputerUseTextSnapshot(
                targetID: field.targetID, value: after,
                selection: NSRange(location: range.location + edit.text.utf16.count, length: 0),
                isEditable: true, isSecure: false)
            finalValues[field.targetID] = after
        }
        self.steps = steps
        self.finalValues = finalValues
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ComputerUseTextTaskError: Error, Equatable {
    case invalidPlan, staleTarget, uncertainEffect, incompleteOutcome, journalMismatch
}

struct ComputerUseTextStepJournal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case planned, attempted, verified, uncertain }
    let taskID: String
    let promptDigest: String
    let stepIDs: [String]
    var statuses: [Status]
}

/// Persist-before-effect, readback-after-effect. Retain this instance on pause.
/// A possibly delivered edit is reconciled, never sent a second time merely
/// because a model proposed it again or the previous call was interrupted.
@MainActor
final class ComputerUseTextTask {
    let contract: ComputerUseTextTaskContract
    private(set) var journal: ComputerUseTextStepJournal
    let read: (String) throws -> ComputerUseTextSnapshot?
    let apply: (ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void
    let persist: (ComputerUseTextStepJournal) throws -> Void
    let mayAct: () -> Bool

    init(contract: ComputerUseTextTaskContract,
         recovered: ComputerUseTextStepJournal? = nil,
         read: @escaping (String) throws -> ComputerUseTextSnapshot?,
         apply: @escaping (ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void,
         persist: @escaping (ComputerUseTextStepJournal) throws -> Void,
         mayAct: @escaping () -> Bool) throws {
        self.contract = contract
        let initial = ComputerUseTextStepJournal(
            taskID: contract.taskID, promptDigest: contract.promptDigest,
            stepIDs: contract.steps.map(\.id), statuses: contract.steps.map { _ in .planned })
        if let recovered {
            guard recovered.taskID == initial.taskID, recovered.promptDigest == initial.promptDigest,
                  recovered.stepIDs == initial.stepIDs, recovered.statuses.count == initial.statuses.count else {
                throw ComputerUseTextTaskError.journalMismatch
            }
        }
        self.journal = recovered ?? initial
        self.read = read
        self.apply = apply
        self.persist = persist
        self.mayAct = mayAct
    }

    func run(progress: (Int, Int) -> Void = { _, _ in }) async throws {
        for (index, step) in contract.steps.enumerated() {
            await Task.yield()
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseTextEditError.interrupted }
            if journal.statuses[index] == .verified { continue }
            guard index == 0 || journal.statuses[index - 1] == .verified,
                  let current = try read(step.targetID), current.targetID == step.targetID,
                  current.isEditable, !current.isSecure else {
                throw ComputerUseTextTaskError.staleTarget
            }
            if journal.statuses[index] != .planned {
                // Readback can establish the exact outcome after an interrupted
                // call, but matching the old value cannot prove no effect.
                guard current.value.utf8.elementsEqual(step.after.utf8) else {
                    try transition(index, to: .uncertain)
                    throw ComputerUseTextTaskError.uncertainEffect
                }
                try transition(index, to: .verified)
                continue
            }
            // Verify the latest completed state of each field before starting
            // another effect, including after a pause between fields.
            var completedValues: [String: String] = [:]
            for prior in 0..<index where journal.statuses[prior] == .verified {
                completedValues[contract.steps[prior].targetID] = contract.steps[prior].after
            }
            for (id, value) in completedValues {
                guard let observed = try read(id), observed.targetID == id,
                      observed.value.utf8.elementsEqual(value.utf8),
                      observed.isEditable, !observed.isSecure else {
                    throw ComputerUseTextTaskError.incompleteOutcome
                }
            }
            guard current.value.utf8.elementsEqual(step.before.utf8),
                  step.insertionSelection.map({ $0 == current.selection }) ?? true else {
                throw ComputerUseTextTaskError.staleTarget
            }
            try transition(index, to: .attempted)
            do {
                try await apply(ComputerUseTextPlanEdit(
                    targetID: step.targetID, mode: step.mode, text: step.payload), current)
                guard let after = try read(step.targetID), after.targetID == step.targetID,
                      after.isEditable, !after.isSecure,
                      after.value.utf8.elementsEqual(step.after.utf8) else {
                    throw ComputerUseTextTaskError.uncertainEffect
                }
                try transition(index, to: .verified)
                progress(index + 1, contract.steps.count)
            } catch {
                // The attempted marker has already reached durable storage.
                // Preserve it if cancellation or persistence fails.
                if !(error is CancellationError) {
                    try? transition(index, to: .uncertain)
                }
                throw error
            }
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        for (id, value) in contract.finalValues {
            guard let current = try read(id), current.targetID == id,
                  current.isEditable, !current.isSecure,
                  current.value.utf8.elementsEqual(value.utf8) else {
                throw ComputerUseTextTaskError.incompleteOutcome
            }
        }
    }

    private func transition(_ index: Int, to status: ComputerUseTextStepJournal.Status) throws {
        var next = journal
        next.statuses[index] = status
        try persist(next)
        journal = next
    }
}

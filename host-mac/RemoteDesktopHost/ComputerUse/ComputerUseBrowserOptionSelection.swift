import Foundation

enum ComputerUseBrowserOptionSelectionError: Error, Equatable {
    case invalidIntent, unavailable, uncertain, retired, retirementPending, busy
}

/// Whole scoped choice state, with an explicit single-selection convention.
/// Neither focus nor the owner's typed/displayed text substitutes for it.
enum ComputerUseBrowserOptionSelectionState {
    struct Reading {
        let object: [String: Any]
        let mode: String
        let options: [[String: Any]]
        let selectedID: String?
        let identity: Data
    }
    static func read(_ value: String, control: ComputerUseBrowserPageSnapshot.Control) -> Reading? {
        guard var graph = ComputerUseBrowserCompositeState.object(value, control: control),
              let attributes = graph["attributes"] as? [String: String],
              let list = graph["list_attributes"] as? [String: String],
              list["aria-multiselectable"] != "true", attributes["aria-multiselectable"] != "true",
              let options = graph["options"] as? [[String: Any]], !options.isEmpty else { return nil }
        let mode: String
        if options.allSatisfy({ $0["selected"] is String && $0["checked"] is NSNull }) { mode = "selected" }
        else if options.allSatisfy({ $0["checked"] is String && $0["selected"] is NSNull }),
                options.allSatisfy({ ["true", "false"].contains($0["checked"] as? String ?? "") }) { mode = "checked" }
        else { return nil }
        let selected = options.filter { $0[mode] as? String == "true" }.compactMap { $0["id"] as? String }
        guard selected.count <= 1 else { return nil }
        let original = graph
        for key in ["input_value", "display_text", "active_option", "list_active_option", "list_hidden"] { graph.removeValue(forKey: key) }
        var fixedAttributes = attributes, fixedList = list
        for key in ["aria-expanded", "aria-busy"] { fixedAttributes.removeValue(forKey: key); fixedList.removeValue(forKey: key) }
        graph["attributes"] = fixedAttributes; graph["list_attributes"] = fixedList
        graph["options"] = options.map { option -> [String: Any] in
            var fixed = option
            for key in ["selected", "checked", "hidden"] { fixed.removeValue(forKey: key) }
            fixed["groups"] = (option["groups"] as? [[String: Any]] ?? []).map { group -> [String: Any] in
                var fixed = group; fixed.removeValue(forKey: "hidden"); return fixed
            }
            return fixed
        }
        guard let identity = try? JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]) else { return nil }
        return .init(object: original, mode: mode, options: options, selectedID: selected.first, identity: identity)
    }
    static func isReady(_ reading: Reading) -> Bool {
        guard reading.object["list_disabled"] as? Bool == false,
              let attributes = reading.object["attributes"] as? [String: String],
              let list = reading.object["list_attributes"] as? [String: String] else { return false }
        return [attributes, list].allSatisfy { $0["aria-busy"] != "true" && $0["aria-readonly"] != "true" && $0["aria-disabled"] != "true" }
    }

    static func baselineDigest(controlIDs: [String], page: ComputerUseBrowserPageSnapshot) throws -> String {
        try ComputerUseBrowserObservedCriteria.digest(controlIDs: controlIDs, page: page)
    }
}

struct ComputerUseBrowserOptionSelectionIntent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserPageEvidence
    let controlID: String
    let optionID: String
    let requirementIndex: Int
    let observedPreservedControlIDs: [String]
    let selectionMode: String
    let needsDispatch: Bool
    let baselineDigest: String
    let scopeReview: ComputerUseBrowserEffectScopeReview?
    init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence,
         controlID: String, optionID: String, requirementIndex: Int, scopeReview: ComputerUseBrowserEffectScopeReview? = nil) throws {
        let invalid = ComputerUseBrowserOptionSelectionError.invalidIntent
        guard interpretation.input.taskID == evidence.document.taskID, interpretation.disposition == .research,
              interpretation.requirements.indices.contains(requirementIndex),
              ComputerUseBrowserControlRead.accepts(interpretation.requirements[requirementIndex]),
              evidence.page.isWellFormed, evidence.page.controlStateObserved, evidence.page.scopedControlIDs.contains(controlID),
              ComputerUseBrowserObservedCriteria.hasAvailableScopedCriteria(in: evidence.page, excluding: controlID),
              let control = evidence.page.controls.first(where: { $0.id == controlID }),
              control.compositeRole != nil, !control.disabled, !control.readOnly,
              let value = evidence.page.controlStates.first(where: { $0.controlID == controlID && $0.kind == .composite })?.value,
              let reading = ComputerUseBrowserOptionSelectionState.read(value, control: control),
              ComputerUseBrowserOptionSelectionState.isReady(reading), reading.object["list_hidden"] as? Bool == false,
              control.compositeRole != "combobox" || (reading.object["attributes"] as? [String: String])?["aria-expanded"] == "true",
              let option = reading.options.first(where: { $0["id"] as? String == optionID }),
              option["disabled"] as? Bool == false, option["hidden"] as? Bool == false else { throw invalid }
        let ids = Set(reading.options.compactMap { $0["id"] as? String })
        var preserved: [String] = []
        for state in evidence.page.controlStates where state.controlID != controlID && state.kind != .unavailable && state.kind != .stateless {
            guard let other = evidence.page.controls.first(where: { $0.id == state.controlID }) else { throw invalid }
            if state.kind == .composite, let value = state.value,
               let graph = ComputerUseBrowserCompositeState.object(value, control: other),
               let options = graph["options"] as? [[String: Any]], Set(options.compactMap { $0["id"] as? String }) == ids {
                guard other.compositeRole == "listbox", control.compositeRole == "combobox" else { throw invalid }
                continue // Another scoped view of this exact native option set.
            }
            preserved.append(state.controlID)
        }
        guard scopeReview == nil || (scopeReview?.formScope == nil && scopeReview?.matches(interpretation: interpretation, evidence: evidence) == true) else { throw ComputerUseBrowserOptionSelectionError.invalidIntent }
        self.scopeReview = scopeReview
        self.interpretation = interpretation; self.evidence = evidence; self.controlID = controlID; self.optionID = optionID
        self.requirementIndex = requirementIndex; observedPreservedControlIDs = preserved
        selectionMode = reading.mode; needsDispatch = reading.selectedID != optionID
        baselineDigest = try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: [controlID] + preserved, page: evidence.page)
    }
    var description: String { "BrowserOptionSelectionIntent" }
    var debugDescription: String { description }
}

struct ComputerUseBrowserOptionSelectionBinding: Decodable, Equatable, Sendable {
    let id: String
    let controlID: String
    let optionID: String
    let needsDispatch: Bool
    func matches(_ intent: ComputerUseBrowserOptionSelectionIntent) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && controlID == intent.controlID && optionID == intent.optionID && needsDispatch == intent.needsDispatch
    }
}
/// Eligible native IDs under one already-scoped whole option graph. Candidate
/// discovery allocates no executable binding and dispatches no events.
struct ComputerUseBrowserOptionSelectionChoice: Decodable, Equatable, Sendable {
    let controlID: String
    let optionIDs: [String]
    func isValid(in evidence: ComputerUseBrowserPageEvidence) -> Bool {
        guard evidence.page.controlStateObserved, evidence.page.scopedControlIDs.contains(controlID),
              ComputerUseBrowserObservedCriteria.hasAvailableScopedCriteria(in: evidence.page, excluding: controlID),
              let control = evidence.page.controls.first(where: { $0.id == controlID }), !control.disabled, !control.readOnly,
              let value = evidence.page.controlStates.first(where: { $0.controlID == controlID && $0.kind == .composite })?.value,
              let state = ComputerUseBrowserOptionSelectionState.read(value, control: control),
              ComputerUseBrowserOptionSelectionState.isReady(state), state.object["list_hidden"] as? Bool == false,
              control.compositeRole != "combobox" || (state.object["attributes"] as? [String: String])?["aria-expanded"] == "true",
              !optionIDs.isEmpty, optionIDs.count <= 64, Set(optionIDs).count == optionIDs.count else { return false }
        return optionIDs.allSatisfy { id in state.options.contains { $0["id"] as? String == id
            && $0["disabled"] as? Bool == false && $0["hidden"] as? Bool == false } }
    }
}
struct ComputerUseBrowserOptionSelectionTarget: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let intent: ComputerUseBrowserOptionSelectionIntent
    let binding: ComputerUseBrowserOptionSelectionBinding
    var payloadDigest: String {
        ComputerUseTaskContract.digest([intent.scopeReview == nil ? "browser-option-selection-v2" : "browser-option-selection-v3",intent.interpretation.input.digest,
            intent.evidence.document.contextID,intent.evidence.documentID,intent.evidence.page.id,binding.id,
            intent.controlID,intent.optionID,String(intent.requirementIndex),intent.selectionMode,
            String(intent.needsDispatch),intent.baselineDigest]
            + intent.observedPreservedControlIDs + (intent.scopeReview.map { [$0.digest] } ?? []))
    }
    var description: String { "BrowserOptionSelectionTarget" }
    var debugDescription: String { description }
}
/// Historical declared selection plus a separate input/display observation.
/// It cannot establish an accepted backend code, inventory, price or refresh.
struct ComputerUseBrowserOptionSelectionReceipt: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let operationID: String
    let bindingID: String
    let controlID: String
    let optionID: String
    let documentID: String
    let didDispatch: Bool
    let afterValue: String
    let preservedControlIDs: [String]
    func validates(_ target: ComputerUseBrowserOptionSelectionTarget, operationID: String) -> Bool {
        let intent = target.intent
        guard target.binding.matches(intent), self.operationID == operationID, bindingID == target.binding.id, controlID == intent.controlID,
              optionID == intent.optionID, documentID == intent.evidence.documentID, didDispatch == intent.needsDispatch,
              preservedControlIDs == intent.observedPreservedControlIDs,
              let control = intent.evidence.page.controls.first(where: { $0.id == controlID }),
              let beforeValue = intent.evidence.page.controlStates.first(where: { $0.controlID == controlID })?.value,
              let before = ComputerUseBrowserOptionSelectionState.read(beforeValue, control: control),
              let after = ComputerUseBrowserOptionSelectionState.read(afterValue, control: control) else { return false }
        return before.mode == after.mode && before.identity == after.identity && after.selectedID == optionID
            && ComputerUseBrowserOptionSelectionState.isReady(after)
    }
    var description: String { "BrowserOptionSelectionReceipt" }
    var debugDescription: String { description }
}

extension ComputerUseOwnedBrowser {
    func optionSelectionChoices(in evidence: ComputerUseBrowserPageEvidence) async throws -> [ComputerUseBrowserOptionSelectionChoice] {
        try requireSelectionContext(evidence.document)
        guard evidence.page.isWellFormed, evidence.page.controlStateObserved else { throw ComputerUseBrowserOptionSelectionError.invalidIntent }
        let result = try await callDOM(.optionSelectionCandidates, arguments: ["documentID":evidence.documentID,
            "snapshotID":evidence.page.id], document: evidence.document)
        try requireSelectionContext(evidence.document)
        guard result.status == "selection-candidates", result.documentID == evidence.documentID,
              let choices = result.optionSelectionCandidates, choices.count <= 16,
              Set(choices.map(\.controlID)).count == choices.count,
              choices.reduce(0, { $0 + $1.optionIDs.count }) <= 128 else { throw ComputerUseBrowserOptionSelectionError.unavailable }
        guard choices.allSatisfy({ $0.isValid(in: evidence) }) else { throw ComputerUseBrowserOptionSelectionError.unavailable }
        return choices
    }

    func prepareOptionSelection(_ intent: ComputerUseBrowserOptionSelectionIntent) async throws -> ComputerUseBrowserOptionSelectionTarget {
        try requireSelectionContext(intent.evidence.document)
        let result = try await callDOM(.prepareOptionSelection, arguments: ["documentID":intent.evidence.documentID,
            "snapshotID":intent.evidence.page.id,"controlID":intent.controlID,"optionID":intent.optionID], document: intent.evidence.document)
        try requireSelectionContext(intent.evidence.document)
        guard result.status == "selection-prepared", result.documentID == intent.evidence.documentID, let binding = result.optionSelectionBinding,
              binding.matches(intent),
              result.selectionPreservedControls == intent.observedPreservedControlIDs else { throw ComputerUseBrowserOptionSelectionError.unavailable }
        return .init(intent: intent, binding: binding)
    }
    func validateOptionSelection(_ target: ComputerUseBrowserOptionSelectionTarget) async throws {
        try requireSelectionContext(target.intent.evidence.document)
        let result = try await callDOM(.validateOptionSelection, arguments: selectionArguments(target), document: target.intent.evidence.document)
        try requireSelectionContext(target.intent.evidence.document)
        guard result.status == "selection-current", result.documentID == target.intent.evidence.documentID else { throw ComputerUseBrowserOptionSelectionError.unavailable }
    }
    /// Requires the caller to persist the exact attempt and retain ownership.
    /// Not exposed in the ordinary planner until its journaled stage is wired.
    func dispatchOptionSelection(_ target: ComputerUseBrowserOptionSelectionTarget, operationID: String,
                                 willBeginEffect: () throws -> Void) async throws {
        try requireSelectionContext(target.intent.evidence.document)
        var arguments = selectionArguments(target); arguments["operationID"] = try selectionOperationID(operationID)
        try willBeginEffect(); try requireSelectionContext(target.intent.evidence.document)
        let result = try await callDOM(.selectOption, arguments: arguments, document: target.intent.evidence.document)
        try requireSelectionContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID, ["selection-dispatched","selection-already-attempted"].contains(result.status) else {
            throw ComputerUseBrowserOptionSelectionError.uncertain
        }
    }
    func optionSelectionReceipt(_ target: ComputerUseBrowserOptionSelectionTarget, operationID: String) async throws -> ComputerUseBrowserOptionSelectionReceipt? {
        try requireSelectionContext(target.intent.evidence.document)
        var arguments = selectionArguments(target); arguments["operationID"] = try selectionOperationID(operationID)
        let result = try await callDOM(.optionSelectionReceipt, arguments: arguments, document: target.intent.evidence.document)
        try requireSelectionContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID else { throw ComputerUseBrowserOptionSelectionError.uncertain }
        if result.status == "selection-pending", result.optionSelectionReceipt == nil { return nil }
        guard result.status == "selection-confirmed", let receipt = result.optionSelectionReceipt,
              receipt.validates(target, operationID: operationID) else { throw ComputerUseBrowserOptionSelectionError.uncertain }
        return receipt
    }
    func retireUnsentOptionSelection(_ target: ComputerUseBrowserOptionSelectionTarget, operationID: String) async throws -> Bool {
        try requireSelectionContext(target.intent.evidence.document)
        var arguments = selectionArguments(target); arguments["operationID"] = try selectionOperationID(operationID)
        let result = try await callDOM(.retireUnsentOptionSelection, arguments: arguments, document: target.intent.evidence.document)
        try requireSelectionContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID else { throw ComputerUseBrowserOptionSelectionError.uncertain }
        if result.status == "selection-attempted" { return false }
        guard result.status == "selection-retired-unsent" else { throw ComputerUseBrowserOptionSelectionError.uncertain }
        return true
    }
    private func requireSelectionContext(_ document: ComputerUseBrowserDocument) throws {
        try Task.checkCancellation()
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        try validateSourceDocument(document)
    }
    private func selectionArguments(_ target: ComputerUseBrowserOptionSelectionTarget) -> [String: Any] {
        ["documentID":target.intent.evidence.documentID,"snapshotID":target.intent.evidence.page.id,
         "bindingID":target.binding.id,"controlID":target.intent.controlID,"optionID":target.intent.optionID]
    }
    private func selectionOperationID(_ id: String) throws -> String {
        guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ComputerUseBrowserOptionSelectionError.invalidIntent
        }
        return id
    }
}

import Foundation

/// Original observed settings, independent of the action that must preserve
/// them. A fingerprint is not a current provider result or semantic authority.
enum ComputerUseBrowserObservedCriteria {
    static func hasAvailableScopedCriteria(in page: ComputerUseBrowserPageSnapshot, excluding controlID: String) -> Bool {
        page.scopedControlIDs.filter { $0 != controlID }.allSatisfy { id in
            page.controlStates.contains { $0.controlID == id && $0.kind != .unavailable && $0.kind != .stateless }
        }
    }

    /// Freeze the complete observed baseline in the contract without writing
    /// its private values to the journal. Presence/count fields keep optional
    /// values and variable-length lists distinct under length-prefixed hashing.
    static func digest(controlIDs: [String], page: ComputerUseBrowserPageSnapshot) throws -> String {
        var parts = ["browser-option-selection-baseline-v1", String(controlIDs.count)]
        for id in controlIDs {
            guard let control = page.controls.first(where: { $0.id == id }),
                  let state = page.controlStates.first(where: { $0.controlID == id }), state.isValid(for: control) else {
                throw ComputerUseBrowserOptionSelectionError.invalidIntent
            }
            parts += metadataParts(control)
            parts += [state.kind.rawValue, String(state.value != nil), state.value ?? "",
                String(state.selectedOptionIDs != nil), String(state.selectedOptionIDs?.count ?? 0)]
            parts += state.selectedOptionIDs ?? []
            parts += [state.checked.map { String($0) } ?? "absent", state.indeterminate.map { String($0) } ?? "absent"]
        }
        return ComputerUseTaskContract.digest(parts)
    }

    /// Native metadata must still mean the original thing before a recovery
    /// read. This includes private option codes and exact UTF-8 label bytes.
    static func metadataDigest(controlIDs: [String], page: ComputerUseBrowserPageSnapshot) throws -> String {
        var parts = ["browser-observed-control-metadata-v1", String(controlIDs.count)]
        for id in controlIDs {
            guard let control = page.controls.first(where: { $0.id == id }) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            parts += metadataParts(control)
        }
        return ComputerUseTaskContract.digest(parts)
    }

    private static func metadataParts(_ control: ComputerUseBrowserPageSnapshot.Control) -> [String] {
        var parts = [control.id, control.containerID, control.label, control.kind, control.name,
            String(control.disabled), String(control.readOnly), String(control.required), String(control.multiple),
            String(control.researchReadable), control.compositeRole ?? "", String(control.constraints.count)]
        for (key, value) in control.constraints.sorted(by: { $0.key < $1.key }) { parts += [key, value] }
        parts.append(String(control.options.count))
        for option in control.options {
            parts += [option.id, option.label, option.value, option.groupLabel, String(option.disabled), String(option.hidden)]
        }
        parts.append(String(control.form != nil))
        if let form = control.form { parts += [form.id, form.method, form.action, form.target, form.encoding, String(form.noValidate)] }
        return parts
    }

    static func context(controlIDs: [String], original: ComputerUseBrowserPageEvidence,
                        current: ComputerUseBrowserPageEvidence, projected: Set<String>) throws -> [[String: Any]] {
        let sameDocument = original.document == current.document && original.documentID == current.documentID
        return try controlIDs.map { id in
            guard let control = original.page.controls.first(where: { $0.id == id }),
                  let state = original.page.controlStates.first(where: { $0.controlID == id }) else {
                throw ComputerUseBrowserActionPlanError.invalidInput
            }
            return ["label":control.label,"kind":control.kind,"read_only":control.readOnly,"disabled":control.disabled,
                "required":control.required,"multiple":control.multiple,"constraints":control.constraints,
                "current_control":sameDocument && projected.contains(id) ? id as Any : NSNull(),
                "historical_state":state.plannerContext,
                "native_option_labels":control.options.map { ["id":$0.id,"label":$0.label,"group_label":$0.groupLabel,"disabled":$0.disabled,"hidden":$0.hidden] as [String: Any] }]
        }
    }

    /// Compare the original baseline, never a value recaptured after an effect.
    static func requireUnchanged(controlIDs: [String], original: ComputerUseBrowserPageEvidence,
                                 current: ComputerUseBrowserPageEvidence) throws {
        guard !controlIDs.isEmpty else { return }
        guard original.document == current.document, original.documentID == current.documentID,
              try digest(controlIDs: controlIDs, page: original.page) == digest(controlIDs: controlIDs, page: current.page) else {
            throw ComputerUseBrowserResearchTask.Failure.observedCriteriaChanged
        }
    }

    // Shared native identity/value checks used by popup and option effects.
    static let script = #"""
      function observedControlMetadata(binding) {
        const metadata = {...binding.metadata}; delete metadata.containerID;
        return JSON.stringify(metadata);
      }
      function observedControlReferences(binding) {
        const references = new Set();
        const starts = [binding.element,...binding.references,...labelFor(binding.element).labels];
        if (binding.element.form) starts.push(binding.element.form);
        for (const start of starts) {
          let reached = false;
          for (let node = start, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
            references.add(node);
            if (references.size > 4096) return null;
            if (node === root) { reached = true; break; }
          }
          if (!reached) return null;
        }
        return Array.from(references);
      }
      function observedControlRecord(id,binding) {
        const references = observedControlReferences(binding);
        return references ? {id,binding,metadata:observedControlMetadata(binding),state:JSON.stringify(binding.state),
          references,form:binding.element.form || null} : null;
      }
      function observedControlMatches(expected,current) {
        const references = current && observedControlReferences(current);
        return !!references && current.element === expected.binding.element && (current.element.form || null) === expected.form
          && observedControlMetadata(current) === expected.metadata && JSON.stringify(current.state) === expected.state
          && references.length === expected.references.length && references.every((node,index) => node === expected.references[index]);
      }
    """#
}

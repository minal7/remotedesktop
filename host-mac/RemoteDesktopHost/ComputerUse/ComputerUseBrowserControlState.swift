import Foundation

/// A research-only observation of a control, never an edit or proof
/// that this selection belongs to an offer. Option submission codes stay private.
struct ComputerUseBrowserControlState: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: String, Decodable, Sendable { case scalar, text, selection, checked, declared, composite, stateless, unavailable }
    let controlID: String
    let kind: Kind
    let value: String?
    let selectedOptionIDs: [String]?
    let checked: Bool?
    let indeterminate: Bool?

    func requiresScope(for control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        kind == .text || kind == .declared || kind == .composite || (kind != .stateless && kind != .unavailable && (control.disabled || control.readOnly))
    }

    // Shape validation only. The complete snapshot separately requires scope
    // membership for text, declared and read-only/disabled value observations,
    // and for every available value when an explicit scope is present.
    func isValid(for control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        guard controlID == control.id else { return false }
        guard control.compositeRole == nil || kind == .composite || kind == .unavailable else { return false }
        switch kind {
        case .composite:
            return ComputerUseBrowserControlRead.allows(control) && value.flatMap { ComputerUseBrowserCompositeState.object($0, control: control) } != nil
                && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        case .declared:
            return ComputerUseBrowserControlRead.allows(control) && value.flatMap { ComputerUseBrowserDeclaredState.attributes($0, kind: control.kind) } != nil
                && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        case .text:
            return ["text", "search"].contains(control.kind) && ComputerUseBrowserControlRead.allows(control)
                && value != nil && (value?.utf8.count ?? 0) <= 2_048
                && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        case .scalar:
            return ["date", "datetime-local", "month", "week", "time", "number"].contains(control.kind)
                && ((!control.disabled && !control.readOnly) || ComputerUseBrowserControlRead.allows(control))
                && value != nil && (value?.utf8.count ?? 0) <= 2_048
                && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        case .selection:
            guard control.kind == "select", (!control.disabled && !control.readOnly) || ComputerUseBrowserControlRead.allows(control),
                  value == nil, checked == nil, indeterminate == nil,
                  let selectedOptionIDs, Set(selectedOptionIDs).count == selectedOptionIDs.count,
                  Set(selectedOptionIDs).isSubset(of: Set(control.options.map(\.id))),
                  control.multiple || selectedOptionIDs.count <= 1 else { return false }
            return control.options.filter { selectedOptionIDs.contains($0.id) }.map(\.id) == selectedOptionIDs
        case .checked:
            return ["checkbox", "radio"].contains(control.kind)
                && ((!control.disabled && !control.readOnly) || ComputerUseBrowserControlRead.allows(control))
                && value == nil && selectedOptionIDs == nil
                && checked != nil && indeterminate != nil && (control.kind == "checkbox" || indeterminate == false)
        case .stateless:
            return ["button", "submit", "reset", "image"].contains(control.kind)
                && value == nil && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        case .unavailable:
            return value == nil && selectedOptionIDs == nil && checked == nil && indeterminate == nil
        }
    }

    /// The entire observed scalar, scoped text, declaration or selected option labels. A checked flag
    /// is not a numeric quantity; a selection is never available inventory.
    func fieldSource(for control: ComputerUseBrowserPageSnapshot.Control) -> String? {
        if kind == .declared, let value, let attributes = ComputerUseBrowserDeclaredState.attributes(value, kind: control.kind),
           attributes["aria-checked"] == "mixed" || attributes["aria-pressed"] == "mixed" { return nil }
        guard indeterminate != true, let value = observedValue(for: control),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func observedValue(for control: ComputerUseBrowserPageSnapshot.Control) -> String? {
        guard isValid(for: control) else { return nil }
        switch kind {
        case .scalar, .text, .declared, .composite: return value
        case .selection:
            let ids = selectedOptionIDs ?? []
            return control.options.filter { ids.contains($0.id) }.map {
                $0.groupLabel.isEmpty ? $0.label : $0.groupLabel + ": " + $0.label
            }.joined(separator: "\n")
        case .checked: return indeterminate == true ? "Mixed" : (checked == true ? "Checked" : "Not checked")
        case .stateless, .unavailable: return nil
        }
    }

    var plannerContext: [String: Any] {
        var result: [String: Any] = ["kind":kind.rawValue]
        if kind == .declared || kind == .composite { result["provenance"] = "websiteDeclaredARIA" }
        if let value {
            if kind == .declared || kind == .composite, let attributes = try? JSONSerialization.jsonObject(with: Data(value.utf8)) {
                result[kind == .composite ? "composite_observation" : "declared_attributes"] = attributes
                if kind == .composite, (attributes as? [String: Any])?["input_value"] is String { result["input_value_provenance"] = "nativeInputProperty" }
            } else { result["value"] = value }
        }
        if let selectedOptionIDs { result["selected_options"] = selectedOptionIDs }
        if let checked { result["checked"] = checked }
        if let indeterminate { result["indeterminate"] = indeterminate }
        return result
    }

    func renderedObservation(for control: ComputerUseBrowserPageSnapshot.Control) -> String {
        let quote = AppleFoundationVisualActionRouter.foundationJSONString
        var lines = [quote(control.label) + " (" + control.kind + "): " + (observedValue(for: control).map(quote) ?? (kind == .stateless ? "Action control; no selected value." : "State unavailable.")),
            "Disabled: \(control.disabled); read only: \(control.readOnly); required: \(control.required); multiple: \(control.multiple)."]
        if let checked, let indeterminate { lines.append("Checked: \(checked); indeterminate: \(indeterminate).") }
        if kind == .declared { lines.append("Website-declared accessibility state; not a native input value or provider result.") }
        if kind == .composite { lines.append("Website-declared options, selections and focus; typed input text is recorded separately. Focus is not selection, and these settings do not prove provider results.") }
        for (key, value) in control.constraints.sorted(by: { $0.key < $1.key }) { lines.append(key + ": " + quote(value)) }
        for option in control.options {
            lines.append("Option " + quote(option.label) + (option.groupLabel.isEmpty ? "" : " in " + quote(option.groupLabel))
                + "; selected: \((selectedOptionIDs ?? []).contains(option.id)); disabled: \(option.disabled); hidden: \(option.hidden).")
        }
        return lines.joined(separator: "\n")
    }

    var byteCount: Int { controlID.utf8.count + (value?.utf8.count ?? 0) + (selectedOptionIDs ?? []).reduce(0) { $0 + $1.utf8.count } + 64 }
    var description: String { "BrowserControlState(kind: \(kind.rawValue))" }
    var debugDescription: String { description }
}

import Foundation

/// A research-only observation of a native control, never an edit or proof
/// that this selection belongs to an offer. Option submission codes stay private.
struct ComputerUseBrowserControlState: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: String, Decodable, Sendable { case scalar, text, selection, checked, stateless, unavailable }
    let controlID: String
    let kind: Kind
    let value: String?
    let selectedOptionIDs: [String]?
    let checked: Bool?
    let indeterminate: Bool?

    func requiresScope(for control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        kind == .text || (kind != .stateless && kind != .unavailable && (control.disabled || control.readOnly))
    }

    // Shape validation only. The complete snapshot separately requires scope
    // membership for text states and read-only/disabled value observations.
    func isValid(for control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        guard controlID == control.id else { return false }
        switch kind {
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

    /// The entire observed scalar, scoped text or selected option labels. A checked flag
    /// is not a numeric quantity; a selection is never available inventory.
    func fieldSource(for control: ComputerUseBrowserPageSnapshot.Control) -> String? {
        guard indeterminate != true, let value = observedValue(for: control),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func observedValue(for control: ComputerUseBrowserPageSnapshot.Control) -> String? {
        guard isValid(for: control) else { return nil }
        switch kind {
        case .scalar, .text: return value
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
        if let value { result["value"] = value }
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

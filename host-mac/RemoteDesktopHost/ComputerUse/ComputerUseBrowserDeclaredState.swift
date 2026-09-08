import Foundation

/// Literal website accessibility declarations, not native input properties.
/// Keep the whole attribute set together; do not turn one numeric substring
/// into a quantity, price, date, successful edit or provider result fact.
enum ComputerUseBrowserDeclaredState {
    static let kinds: Set<String> = ["aria-checkbox", "aria-radio", "aria-switch", "aria-button", "aria-slider", "aria-spinbutton"]
    static func attributes(_ value: String, kind: String) -> [String: String]? {
        guard kinds.contains(kind), value.utf8.count <= 2_048 else { return nil }
        var parser = StrictSemanticJSONParser(value, maximumValueCount: 16)
        guard let parsed = try? parser.parse(), case .object(let object) = parsed else { return nil }
        var attributes: [String: String] = [:]
        for (key, value) in object {
            guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 512 else { return nil }
            attributes[key] = text
        }
        if ["aria-checkbox", "aria-radio", "aria-switch", "aria-button"].contains(kind) {
            let key = kind == "aria-button" ? "aria-pressed" : "aria-checked"
            guard Set(attributes.keys) == [key], let state = attributes[key],
                  ["true", "false"].contains(state) || (state == "mixed" && ["aria-checkbox", "aria-button"].contains(kind)) else { return nil }
        } else {
            guard Set(attributes.keys).isSubset(of: ["aria-valuenow", "aria-valuemin", "aria-valuemax", "aria-valuetext"]),
                  let now = number(attributes["aria-valuenow"]) else { return nil }
            for key in ["aria-valuemin", "aria-valuemax"] where attributes[key] != nil {
                guard number(attributes[key]) != nil else { return nil }
            }
            if let minimum = number(attributes["aria-valuemin"]), minimum > now { return nil }
            if let maximum = number(attributes["aria-valuemax"]), maximum < now { return nil }
        }
        return attributes
    }
    private static func number(_ value: String?) -> Double? {
        guard let value, value.range(of: #"^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

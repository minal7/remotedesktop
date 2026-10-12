import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormPrefixTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    private struct Prepared {
        let input: ComputerUseBrowserResearchFormInput
        let proposal: ComputerUseBrowserFormProposal
    }

    private func actionReview(_ input: ComputerUseBrowserActionInput) throws -> String? {
        let verified = try object(input.contextJSON)["verified_form_stage"] as? [String: Any]
        let edits = verified?["edits"] as? [[String: Any]] ?? []
        let pending = verified?["unfinished_edits"] as? [[String: Any]] ?? []
        let cityIndex = input.interpretation.requirements.firstIndex { $0.sourceTurnIndex == 1 } ?? 0
        var editing: [String: [Int]] = [:], retaining: [String: [Int]] = [:]
        for label in ["Category", "City", "Region"] {
            guard let id = input.evidence.page.controls.first(where: { $0.label == label })?.id else { continue }
            let previous = edits.first { $0["control"] as? String == id }
            if verified == nil || previous?["requires_repair"] as? Bool == true || pending.contains(where: { $0["label"] as? String == label }) {
                editing[label] = [label == "Category" ? 0 : cityIndex]
            } else { retaining[label] = [label == "Category" ? 0 : cityIndex] }
        }
        return try FormEffectScopeFixture.response(input, editing: editing, retaining: retaining)
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        var edits: [[String: Any]] = []
        let pending = input.previous?.pendingEdits ?? []
        let category = try alias("Category", input)
        if input.previous == nil || input.requiredRepairFieldAliases.contains(category) {
            let option = try XCTUnwrap(input.field(for: category).control.options.first { $0.label == "Concerts" })
            edits.append(["field":category,"choice":option.id,"requirement":0])
        }
        for label in ["City", "Region"] where input.evidence.fields.contains(where: { $0.control.label == label }) {
            if input.previous == nil || pending.contains(where: { $0.label == label }) {
                let index = input.interpretation.requirements.firstIndex { $0.sourceTurnIndex == 1 } ?? 0
                edits.append(["field":try alias(label, input),"terms":[["requirement":index,"text":"Paris"]]])
            }
        }
        var content: [String: Any] = ["edits":edits,"preserve":[]]
        if !input.pendingEditAliases.isEmpty {
            content["resume"] = try zip(input.pendingEditAliases, pending).map { ["pending":$0.0,"field":try alias($0.1.label, input)] }
        }
        return try json(content)
    }
    private func alias(_ label: String, _ input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }

    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

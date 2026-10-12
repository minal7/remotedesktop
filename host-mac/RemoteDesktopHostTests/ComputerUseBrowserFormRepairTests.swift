import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormRepairTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."
    private let resetCategory = "document.getElementById('category').selectedIndex = 0;"

    private func formAction(_ input: ComputerUseBrowserActionInput, cityRequirement: Int = 0, initialCity: Bool = true) throws -> String {
        let verified = try object(input.contextJSON)["verified_form_stage"] as? [String: Any]
        let categoryID = input.evidence.page.controls.first { $0.label == "Category" }?.id
        let rows = verified?["edits"] as? [[String: Any]] ?? []
        let repairCategory = verified == nil || rows.contains { $0["control"] as? String == categoryID && $0["requires_repair"] as? Bool == true }
        if let review = try FormEffectScopeFixture.response(input, editing: repairCategory ? (verified == nil && !initialCity ? ["Category":[0]] : ["Category":[0],"City":[cityRequirement]]) : ["City":[cityRequirement]],
            retaining: repairCategory ? [:] : ["Category":[0]], deferring: verified == nil && !initialCity ? ["City":[0]] : [:]) { return review }
        guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
        let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
        return try json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
    }

    private func plan(_ input: ComputerUseBrowserResearchFormInput, category: Bool = true, city: Bool = true,
                      cityValue: String = "Paris", requirement: Int = 0) throws -> String {
        var edits: [[String: Any]] = []
        if category {
            let alias = try self.alias("Category", in: input), field = try input.field(for: alias)
            let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
            edits.append(["field":alias,"choice":option.id,"requirement":0])
        }
        if city { edits.append(try cityEdit(input, value: cityValue, requirement: requirement)) }
        return try json(["edits":edits,"preserve":[]])
    }
    private func cityEdit(_ input: ComputerUseBrowserResearchFormInput, value: String = "Paris", requirement: Int = 0) throws -> [String: Any] {
        ["field":try alias("City", in: input),"terms":[["requirement":requirement,"text":value]]]
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
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

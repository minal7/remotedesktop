import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormExtensionTests: XCTestCase {
    private let request = "Find concerts in Paris. Leave Reference unchanged. Do not buy."
    private let body = """
        <form id='search' action='/filtered'>
          <label>Category<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
          <span id='dependent'></span><button>Search</button>
        </form>
        <label>Reference<input id='reference' value='private-reference'></label>
        <script>document.getElementById('category').addEventListener('change', () => {
          if (!document.getElementById('city')) document.getElementById('dependent').innerHTML = '<label>City<input id="city" name="city"></label>';
        });</script>
        """

    private func field(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> ComputerUseBrowserFormEvidence.Field {
        try XCTUnwrap(input.evidence.fields.first { $0.control.label == label })
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        let field = try field(label, in: input)
        return try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0)) == field })
    }
    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let control = try field("Category", in: input).control, option = try XCTUnwrap(control.options.first { $0.label == "Concerts" })
        return try json(["edits":[["field":try alias("Category", in: input),"choice":option.id,"requirement":0]],"preserve":[]])
    }
    private func cityPlan(_ input: ComputerUseBrowserResearchFormInput, value: String = "Paris") throws -> String {
        try json(["edits":[["field":try alias("City", in: input),"terms":[["requirement":0,"text":value]]]],"preserve":[]])
    }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

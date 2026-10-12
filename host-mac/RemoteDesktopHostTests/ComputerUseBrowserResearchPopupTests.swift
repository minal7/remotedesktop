import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchPopupTests: XCTestCase {

    private func page(handler: String = "this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; fetch('/opened');", unsupported: Bool = false) -> String {
        """
        <article><h2>Concert Alpha</h2><a href='/details'>Alpha details</a>
        <button type=button role=combobox aria-label='Ticket type' aria-controls=choices aria-expanded=false onclick="\(handler)">Choose type</button>
        <div id=choices role=listbox aria-label='Ticket types' hidden><div role=option aria-selected=false>General admission</div></div>
        </article>
        """
        + (unsupported ? "<button role=combobox aria-label='Newsletter settings' aria-controls=unsupported-choices aria-expanded=false>Submit</button>" : "")
    }
    private func inspection(_ input: ComputerUseBrowserActionInput) throws -> String {
        let owner = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Ticket type" })
        return try ResearchAnswerFixture.json(["inspect_options":[["control":owner.id,"requirement":0]]])
    }
    private func opening(_ id: String, requirement: Int = 0) -> String {
        "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":\(requirement)}}"
    }
    private func object(_ string: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(string.utf8)) }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

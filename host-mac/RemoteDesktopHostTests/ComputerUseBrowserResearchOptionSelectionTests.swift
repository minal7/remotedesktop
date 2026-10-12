import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchOptionSelectionTests: XCTestCase {
    private let prompt = "Find concerts. Use general admission. Keep date unchanged. Do not buy."

    func testNativeCandidateDiscoveryDoesNotConsumeBindingsOrDispatchEvents() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let intent = try await OptionSelectionFixture.intent(fixture)
        for _ in 0..<40 {
            let choices = try await fixture.browser.optionSelectionChoices(in: intent.evidence)
            XCTAssertEqual(choices.count, 1); XCTAssertEqual(choices[0].controlID, intent.controlID)
            XCTAssertEqual(choices[0].optionIDs.count, 2); XCTAssertTrue(choices[0].optionIDs.contains(intent.optionID))
        }
        let target = try await fixture.browser.prepareOptionSelection(intent)
        try await fixture.browser.validateOptionSelection(target)
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    private func scope(_ input: ComputerUseBrowserActionInput) throws -> [[String: Any]] {
        let owner = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Ticket type" })
        let date = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Date" })
        return [["control":owner.id,"requirement":1],["control":date.id,"requirement":2]]
    }
    private func inspect(_ input: ComputerUseBrowserActionInput) throws -> String { try ResearchAnswerFixture.json(["inspect_options":scope(input)]) }
    private func read(_ input: ComputerUseBrowserActionInput) throws -> String { try ResearchAnswerFixture.json(["read_results":true,"read_controls":scope(input)]) }
    private func selection(_ control: String, _ option: String, requirement: Int = 1) -> String {
        "{\"select_option\":{\"control\":\"\(control)\",\"option\":\"\(option)\",\"requirement\":\(requirement)}}"
    }

    private func object(_ text: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(text.utf8)) }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

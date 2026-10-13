import XCTest
@testable import RemoteDesktopHost

final class AgentWebEnvironmentTests: XCTestCase {
    func testPageTextIsBoundedReservedAndReadOnly() throws {
        let mapped = try AgentWebObservation.pageTextElement(
            String(repeating: "visible page text ", count: 400),
            screenshotWidth: 800, screenshotHeight: 600,
            bridgeElements: [element(id: 1, role: "button", name: "Continue")])

        let text = try XCTUnwrap(mapped.first)
        XCTAssertEqual(text.id, AgentWebObservation.pageTextElementID)
        XCTAssertEqual(text.role, "page_text")
        XCTAssertEqual(text.value, nil)
        XCTAssertTrue(text.state.contains("read_only"))
        XCTAssertLessThanOrEqual(text.name.count, AgentWebObservation.maximumPageTextCharacters)
        XCTAssertEqual(mapped.last?.id, 1)
        XCTAssertThrowsError(try AgentWebObservation.targetPairs(
            for: .click(target: .element(id: AgentWebObservation.pageTextElementID), button: nil, count: nil),
            in: mapped))
    }

    func testPointClickUsesScreenshotPixelsAtDPROneAndTwo() throws {
        for (viewport, image, box, point) in [
            ([100.0, 100.0], [100.0, 100.0], AgentBoundingBox(x: 20, y: 20, width: 40, height: 30), AgentTarget.point(x: 30, y: 30)),
            ([100.0, 100.0], [200.0, 200.0], AgentBoundingBox(x: 20, y: 20, width: 40, height: 30), AgentTarget.point(x: 60, y: 60)),
        ] {
            let button = element(id: 7, role: "button", name: "Save", bbox: box)
            let pairs = try AgentWebObservation.targetPairs(
                for: .click(target: point, button: nil, count: nil), in: [button])
            let resolved = try AgentWebObservation.resolveTargets(
                pairs, currentElements: [button], viewport: viewport,
                screenshotSize: image)
            XCTAssertEqual(resolved.map(\.id), [7])
        }
    }

    func testPointTypeSelectAndScrollResolveToFreshElements() throws {
        let point = AgentTarget.point(x: 42, y: 32)
        let control = element(id: 9, role: "combobox", name: "Region",
                              bbox: AgentBoundingBox(x: 20, y: 20, width: 50, height: 30))
        let actions: [AgentAction] = [
            .type(target: point, text: "west", mode: .replace),
            .select(target: point, option: "West"),
            .scroll(target: point, direction: .down, amount: 20),
        ]
        for action in actions {
            let pairs = try AgentWebObservation.targetPairs(for: action, in: [control])
            let resolved = try AgentWebObservation.resolveTargets(
                pairs, currentElements: [control], viewport: [100, 100], screenshotSize: [100, 100])
            XCTAssertEqual(resolved.map(\.id), [9], "\(action.type) should resolve its point target")
        }
    }

    func testMovedElementRebindsButGoneChangedCoveredDisabledAndSecureReject() throws {
        let original = element(id: 11, role: "button", name: "Save")
        let action = AgentAction.click(target: .element(id: 11), button: nil, count: nil)
        let pairs = try AgentWebObservation.targetPairs(for: action, in: [original])
        let moved = element(id: 11, role: "button", name: "Save",
                            bbox: AgentBoundingBox(x: 200, y: 150, width: 40, height: 20))
        XCTAssertEqual(try AgentWebObservation.resolveTargets(
            pairs, currentElements: [moved], viewport: [400, 300], screenshotSize: [400, 300]).first?.bbox, moved.bbox)
        XCTAssertThrowsError(try AgentWebObservation.resolveTargets(
            pairs, currentElements: [], viewport: [400, 300], screenshotSize: [400, 300])) { error in
                XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
            }
        XCTAssertThrowsError(try AgentWebObservation.resolveTargets(
            pairs, currentElements: [element(id: 11, role: "button", name: "Delete")],
            viewport: [400, 300], screenshotSize: [400, 300])) { error in
                XCTAssertEqual(error as? AgentEnvironmentError, .targetChanged)
            }
        for (state, expectedError) in [
            (["visible", "covered"], AgentEnvironmentError.targetCovered),
            (["visible", "disabled"], AgentEnvironmentError.disabledTarget),
            (["visible", "secure"], AgentEnvironmentError.credentialHandoff),
        ] {
            let unsafe = element(id: 11, role: "button", name: "Save", state: state)
            XCTAssertThrowsError(try AgentWebObservation.resolveTargets(
                pairs, currentElements: [unsafe], viewport: [400, 300], screenshotSize: [400, 300])) { error in
                    XCTAssertEqual(error as? AgentEnvironmentError, expectedError)
                }
        }
    }

    func testSyntheticPageTextDoesNotInterceptPointHitTesting() throws {
        let button = element(id: 2, role: "button", name: "Open",
                             bbox: AgentBoundingBox(x: 10, y: 10, width: 50, height: 30))
        let mapped = try AgentWebObservation.pageTextElement(
            "Page content", screenshotWidth: 100, screenshotHeight: 100, bridgeElements: [button])
        let pairs = try AgentWebObservation.targetPairs(
            for: .click(target: .point(x: 20, y: 20), button: nil, count: nil), in: mapped)
        let resolved = try AgentWebObservation.resolveTargets(
            pairs, currentElements: mapped, viewport: [100, 100], screenshotSize: [100, 100])
        XCTAssertEqual(resolved.map(\.id), [2])
    }

    private func element(id: Int, role: String, name: String,
                         state: [String] = ["visible", "enabled"],
                         bbox: AgentBoundingBox = AgentBoundingBox(x: 10, y: 10, width: 40, height: 20)) -> AgentElement {
        AgentElement(id: id, role: role, name: name, value: nil, state: state, bbox: bbox, inView: true)
    }
}

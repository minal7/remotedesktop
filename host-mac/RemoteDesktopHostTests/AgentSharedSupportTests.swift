import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentSharedSupportTests: XCTestCase {
    func testAuthorityDigestIsStableAndIncludesFullValueSelectionAndIdentity() throws {
        let base = authorityRecord(value: "prefix-hidden-suffix")
        XCTAssertEqual(try AgentMacAccessibility.AuthorityDigest.encode([base]),
                       try AgentMacAccessibility.AuthorityDigest.encode([base]))

        let changes = [
            authorityRecord(value: "prefix-hidden-other"),
            authorityRecord(value: "prefix-hidden-suffix", selection: .init(start: 2, end: 5)),
            authorityRecord(identifier: "different-control", value: "prefix-hidden-suffix")
        ]
        for changed in changes {
            XCTAssertNotEqual(try AgentMacAccessibility.AuthorityDigest.encode([base]),
                              try AgentMacAccessibility.AuthorityDigest.encode([changed]))
        }
        let other = authorityRecord(id: 9, value: "second")
        XCTAssertEqual(try AgentMacAccessibility.AuthorityDigest.encode([base, other]),
                       try AgentMacAccessibility.AuthorityDigest.encode([other, base]))
    }

    func testCredentialWordsInOrdinaryContentAreNotSecureMarkers() {
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "AXStaticText",
            name: "The instructions mention a password and an OTP", state: ["enabled"]))
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "HotPickButton",
            name: "Choose an item", state: ["enabled"]))
        XCTAssertTrue(AgentCredentialRule.isSensitive(role: "AXTextField",
            name: "One-time code", state: ["enabled"]))
    }

    func testActionTargetExtractionPreservesOnlyTargetsUsedByEachAction() {
        let point = AgentTarget.point(x: 0.4, y: 0.6)
        let first = AgentTarget.element(id: 1)
        let second = AgentTarget.element(id: 2)
        XCTAssertEqual(AgentTargetBinding.targets(.click(target: first, button: nil, count: nil)), [first])
        XCTAssertEqual(AgentTargetBinding.targets(.type(target: point, text: "x", mode: .replace)), [point])
        XCTAssertEqual(AgentTargetBinding.targets(.type(target: nil, text: "x", mode: .replace)), [])
        XCTAssertEqual(AgentTargetBinding.targets(.scroll(target: first, direction: .down, amount: 1)), [first])
        XCTAssertEqual(AgentTargetBinding.targets(.select(target: second, option: "option")), [second])
        XCTAssertEqual(AgentTargetBinding.targets(.setFiles(target: second, fileIDs: ["file"])), [second])
        XCTAssertEqual(AgentTargetBinding.targets(.drag(from: first, to: point)), [first, point])
        XCTAssertEqual(AgentTargetBinding.targets(.key(chord: "tab")), [])
    }

    func testPointHitChoosesSmallestContainingVisibleElement() {
        let elements = [
            element(id: 1, x: 0, y: 0, width: 100, height: 100),
            element(id: 2, x: 20, y: 20, width: 20, height: 20),
            element(id: 3, x: 24, y: 24, width: 4, height: 4, inView: false)
        ]
        XCTAssertEqual(AgentTargetBinding.hit(x: 25, y: 25, elements: elements)?.id, 2)
        XCTAssertEqual(AgentTargetBinding.hit(x: 40, y: 25, elements: elements)?.id, 1)
        XCTAssertNil(AgentTargetBinding.hit(x: 120, y: 120, elements: elements))
    }

    private func authorityRecord(id: Int = 3, role: String = "AXTextField", identifier: String = "query",
                                 value: String, selection: AgentSelection = .init(start: 1, end: 1))
        -> AgentMacAccessibility.EditableAuthorityRecord {
        .init(id: id, role: role, subrole: "", identifier: identifier, name: "Search",
              value: "string:" + value, selected: false, selection: selection)
    }

    private func element(id: Int, x: Double, y: Double, width: Double, height: Double,
                         inView: Bool = true) -> AgentElement {
        .init(id: id, role: "AXButton", name: "Control", value: nil, state: ["enabled"],
              bbox: .init(x: x, y: y, width: width, height: height), inView: inView)
    }
}

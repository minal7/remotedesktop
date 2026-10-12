import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentNativeBackendTests: XCTestCase {
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

    func testTextFallbackRequiresTheIntendedFocusedNonsecureElement() {
        XCTAssertTrue(AgentNativeTextFocusBinding.matches(expectedID: 4, focusedID: 4, isEditable: true, isSecure: false))
        XCTAssertFalse(AgentNativeTextFocusBinding.matches(expectedID: 4, focusedID: 5, isEditable: true, isSecure: false))
        XCTAssertFalse(AgentNativeTextFocusBinding.matches(expectedID: 5, focusedID: 4, isEditable: true, isSecure: false))
        XCTAssertFalse(AgentNativeTextFocusBinding.matches(expectedID: 4, focusedID: 4, isEditable: false, isSecure: false))
        XCTAssertFalse(AgentNativeTextFocusBinding.matches(expectedID: 4, focusedID: 4, isEditable: true, isSecure: true))
    }

    func testAppendFallbackRequiresAConfirmedCollapsedCaretAtTheFullValueEnd() {
        XCTAssertTrue(AgentNativeTextFocusBinding.caretIsAtEnd(.init(start: 12, end: 12), valueLength: 12))
        XCTAssertFalse(AgentNativeTextFocusBinding.caretIsAtEnd(.init(start: 5, end: 5), valueLength: 12))
        XCTAssertFalse(AgentNativeTextFocusBinding.caretIsAtEnd(.init(start: 8, end: 10), valueLength: 12))
        XCTAssertFalse(AgentNativeTextFocusBinding.caretIsAtEnd(nil, valueLength: 12))
    }

    func testCredentialWordsInOrdinaryContentAreNotSecureMarkers() {
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "AXStaticText",
            name: "The instructions mention a password and an OTP", state: ["enabled"]))
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "HotPickButton",
            name: "Choose an item", state: ["enabled"]))
        XCTAssertTrue(AgentCredentialRule.isSensitive(role: "AXTextField",
            name: "One-time code", state: ["enabled"]))
    }

    private func authorityRecord(id: Int = 3, role: String = "AXTextField", identifier: String = "query",
                                 value: String, selection: AgentSelection = .init(start: 1, end: 1))
        -> AgentMacAccessibility.EditableAuthorityRecord {
        .init(id: id, role: role, subrole: "", identifier: identifier, name: "Search",
              value: "string:" + value, selected: false, selection: selection)
    }

}

import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared native/owner regressions; execution remains explicitly deferred.
@MainActor
final class ComputerUseBrowserNativeSettingScopeTests: XCTestCase {
    private let settings = """
        <label>Date<input id=date name=date type=date value=2026-09-20></label>
        <label>Tickets<input id=tickets name=tickets type=number value=2></label>
        <label>Category<select id=category name=category><option value=all>All events</option><option value=concerts>Concerts</option></select></label>
        <label>Direct only<input id=direct name=direct type=checkbox value=1 checked></label>
        <label>Economy fare<input id=fare name=fare type=radio value=economy checked></label>
        <label>Extras<select id=extras name=extras multiple><option value=a selected>First extra</option><option value=b selected>Second extra</option></select></label>
        """
    private let settingsReferences = ["Date":1,"Tickets":1,"Category":1,"Direct only":1,"Economy fare":1,"Extras":1]
    private let queryPath = "/filtered?q=concerts&date=2026-09-20&tickets=2&category=all&direct=1&fare=economy&extras=a&extras=b"

    func testEverySupportedWritableNativeKindCanBeExplicitlyReadWithoutSubmissionCodes() async throws {
        let fixture = try await ControlStateFixture(body: "<form action='/effect'>" + settings + """
            <label>Local departure<input type=datetime-local value=2026-09-20T10:30></label>
            <label>Month<input type=month value=2026-09></label><label>Week<input type=week value=2026-W38></label>
            <label>Time<input type=time value=10:30></label></form>
            """)
        defer { fixture.close() }
        let input = try await context(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 10); XCTAssertFalse(input.evidence.page.controlStateObserved)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: input.readableControlIDs))
        let expected = ["Date":"2026-09-20","Tickets":"2","Category":"All events","Direct only":"Checked",
            "Economy fare":"Checked","Extras":"First extra\nSecond extra","Local departure":"2026-09-20T10:30",
            "Month":"2026-09","Week":"2026-W38","Time":"10:30"]
        for control in reading.page.controls {
            XCTAssertFalse(control.disabled || control.readOnly)
            XCTAssertEqual(try fixture.state(control.label, in: reading.page).fieldSource(for: control), expected[control.label])
        }
        XCTAssertEqual(reading.page.scopedControlIDs, input.readableControlIDs)
        let projected = try ComputerUseBrowserResultPageInput(page: reading.page).contextJSON
        XCTAssertFalse(projected.contains("\"value\":\"all\"")); XCTAssertFalse(projected.contains("\"value\":\"economy\""))
        XCTAssertEqual(fixture.server.count("/effect"), 0)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testExplicitScopeDoesNotImplicitlyReadNeighboringWritableSettings() async throws {
        let fixture = try await ControlStateFixture(body: settings + "<label>Location<input value=Paris></label><label>Notes<input value=private-notes></label>")
        defer { fixture.close() }
        let input = try await context(fixture), location = try control("Location", input)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: [location]))
        for item in reading.page.controls {
            XCTAssertEqual(try fixture.state(item.label, in: reading.page).kind, item.id == location ? .text : .unavailable)
        }
        let projected = try ComputerUseBrowserResultPageInput(page: reading.page).contextJSON
        XCTAssertTrue(projected.contains("Paris")); XCTAssertFalse(projected.contains("2026-09-20")); XCTAssertFalse(projected.contains("private-notes"))
        XCTAssertFalse(reading.page.omittedControlMetadata); XCTAssertTrue(reading.page.omittedControls)
    }

    func testProtectedWritableSettingsRemainIneligibleInSwiftAndNativeScopes() async throws {
        let fixture = try await ControlStateFixture(body: """
            <label>Date<input type=date value=2026-09-20></label>
            <label>Card details<input type=number autocomplete=cc-number value=4111111111111111></label>
            <label>Birth date<input type=date value=1990-01-02></label>
            <label>Billing country<select><option value=private-code>Private country</option></select></label>
            <label>Account preference<input type=checkbox checked></label>
            """)
        defer { fixture.close() }
        let input = try await context(fixture)
        XCTAssertEqual(input.readableControlIDs, [try control("Date", input)])
        for item in input.evidence.page.controls where item.label != "Date" {
            XCTAssertFalse(item.researchReadable)
            XCTAssertThrowsError(try read(input, ids: [item.id]))
            let reply = try await fixture.browser.callDOM(.observeResearchControls, arguments: ["documentID":input.evidence.documentID,
                "snapshotID":input.evidence.page.id,"readControlIDs":[item.id]], document: fixture.document)
            XCTAssertEqual(reply.status, "unsupported"); XCTAssertNil(reply.page)
        }
    }

    func testPropertyOnlyChangesInvalidateEachScopedWritableState() async throws {
        let cases = [("date","value='2026-09-21'"),("tickets","value='3'"),("category","selectedIndex=1"),
            ("direct","checked=false"),("fare","checked=false"),("extras","options[1].selected=false")]
        for (id, mutation) in cases {
            let fixture = try await ControlStateFixture(body: settings + OptionSelectionFixture.signal("document.getElementById('\(id)').\(mutation);"), heldSignal: true)
            defer { fixture.close() }
            let input = try await context(fixture)
            let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: input.readableControlIDs))
            try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validatePageEvidence(reading); XCTFail("A property change cannot preserve the earlier reading: \(id)") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        }
    }

    func testScopedSnapshotRejectsAnAvailableNativeValueOutsideItsDeclaredScope() async throws {
        let fixture = try await ControlStateFixture(body: settings)
        defer { fixture.close() }
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        let input = try await context(fixture), date = try control("Date", input)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: [date])), page = reading.page
        let tickets = try control("Tickets", input)
        let ticketState = try XCTUnwrap(general.page.controlStates.first { $0.controlID == tickets })
        let injected = page.controlStates.map { $0.controlID == tickets ? ticketState : $0 }
        let forged = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
            viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure, controlStates: injected,
            controlStateObserved: true, scopedControlIDs: [date], omittedControlMetadata: page.omittedControlMetadata)
        XCTAssertFalse(forged.isWellFormed); XCTAssertTrue(page.isWellFormed)
    }

    func testMetadataFingerprintPreservesExactLabelBytesBeforeARecoveryRead() async throws {
        let fixture = try await ControlStateFixture(body: "<label id=label>Café<input type=number value=2></label>"
            + OptionSelectionFixture.signal("document.getElementById('label').firstChild.data='Cafe\\u0301';"), heldSignal: true)
        defer { fixture.close() }
        let before = try await fixture.browser.observePage(document: fixture.document)
        let id = try XCTUnwrap(before.page.controls.first?.id)
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let after = try await fixture.browser.observePage(document: fixture.document)
        XCTAssertEqual(before.page.controls.first?.label, after.page.controls.first?.label, "Swift treats these Unicode strings as equivalent")
        XCTAssertNotEqual(try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: [id], page: before.page),
            try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: [id], page: after.page))
        XCTAssertFalse(before.page.controlStateObserved); XCTAssertFalse(after.page.controlStateObserved)
    }

    private enum Mode { case form, query, reviseCategory }

    private var prompt: String { "Find concerts. Review displayed search settings. Leave Reference unchanged. Do not buy." }
    private func goalContent() throws -> String {
        let rows: [[String: Any]] = [
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Review displayed search settings. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Leave Reference unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]]
        return try ResearchAnswerFixture.json(["disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]])
    }
    private func context(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let page = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        return try .init(interpretation: .decode(content: goalContent(), input: goal), evidence: page,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
    }
    private func read(_ input: ComputerUseBrowserActionInput, ids: [String]) throws -> ComputerUseBrowserActionProposal {
        try .decode(content: ResearchAnswerFixture.json(["read_results":true,"read_controls":ids.map { ["control":$0,"requirement":1] as [String: Any] }]), input: input)
    }
    private func control(_ label: String, _ input: ComputerUseBrowserActionInput) throws -> String {
        try XCTUnwrap(input.evidence.page.controls.first { $0.label == label }?.id)
    }

}

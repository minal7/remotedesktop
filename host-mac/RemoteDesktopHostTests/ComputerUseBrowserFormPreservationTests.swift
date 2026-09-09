import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormPreservationTests: XCTestCase {
    func testPrivatePredicatesSupportNativeAndDeclaredSettingsWithoutEditableAliases() async throws {
        let fixture = try await NativeFormPreservationFixture(settings: """
            <label>Reference<input readonly value=privateReference></label>
            <label>Departure<input type=date disabled value=2026-09-20></label>
            <label>Tickets<input type=number readonly value=2></label>
            <label>Fare<select disabled><option value=privateFare selected>Standard</option></select></label>
            <label>Direct<input type=checkbox checked></label><label>Economy<input type=radio checked></label>
            <label>Extras<select multiple><option selected>Bag</option><option selected>Meal</option></select></label>
            <div role=switch aria-label=Alerts aria-checked=false></div>
            <div role=slider aria-label=Distance aria-valuenow=5 aria-valuemin=0 aria-valuemax=10></div>
            """)
        defer { fixture.close() }
        let labels = ["Reference","Departure","Tickets","Fare","Direct","Economy","Extras","Alerts","Distance"]
        let guardBinding = try await fixture.prepare(labels)
        XCTAssertEqual(fixture.fields.map(\.label), ["Query"])
        XCTAssertEqual(guardBinding.controlIDs.count, labels.count)
        XCTAssertFalse(fixture.page.page.controlStateObserved)
        XCTAssertTrue(fixture.page.page.controlStates.isEmpty)
        XCTAssertFalse(String(reflecting: guardBinding).contains("privateReference"))
        XCTAssertFalse(String(reflecting: guardBinding).contains("privateFare"))
        try await fixture.target.validateFormPreservation(guardBinding)
        let fields = try await fixture.target.reobserveRetainedFields()
        XCTAssertEqual(fields, fixture.fields)
    }

    func testPreflightRequiresTheActivePredicateIdentity() async throws {
        let fixture = try await NativeFormPreservationFixture()
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        let missing = try await fixture.native.browser.callDOM(.preflight,
            arguments: ["documentID":binding.documentID,"steps":[["id":"not-a-field","after":"new"]]], document: fixture.native.document)
        XCTAssertEqual(missing.status, "constraint-changed", "Reject a missing predicate before inspecting any target")
        try await fixture.target.validateRepresentability(of: contract)
    }

    func testSuccessfulTextEditRetainsTheOriginalPrivatePredicate() async throws {
        let fixture = try await NativeFormPreservationFixture()
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        try await fixture.apply(contract)
        try await fixture.native.wait { fixture.native.server.count("/input") == 1 }
        let current = try await fixture.target.read(targetID: fixture.initial.targetID)
        XCTAssertEqual(current?.value, "new")
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertTrue(dispatched)
        try await fixture.target.validateFormPreservation(binding)
        XCTAssertEqual(fixture.target.formPreservation, binding)
        XCTAssertEqual(fixture.native.server.count("/change"), 0)
    }

    func testPropertyOnlyChangeBeforeInputBlocksReadPreflightAndDelivery() async throws {
        let fixture = try await NativeFormPreservationFixture(mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        _ = try await fixture.prepare()
        let contract = try fixture.contract()
        try await fixture.releaseMutation()
        let reading = try await fixture.target.read(targetID: fixture.initial.targetID)
        XCTAssertNil(reading)
        await expectFailure { try await fixture.target.validateRepresentability(of: contract) }
        await expectFailure { try await fixture.apply(contract) }
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertFalse(dispatched)
        XCTAssertEqual(fixture.native.server.count("/input"), 0)
    }

    func testTextHandlerViolationRetainsDispatchHistoryAndCannotReplayInput() async throws {
        let fixture = try await NativeFormPreservationFixture(inputHandler: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        await expectFailure { try await fixture.apply(contract) }
        try await fixture.native.wait { fixture.native.server.count("/input") == 1 }
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertTrue(dispatched, "The returned input is historical evidence, even when its handler broke preservation")
        await expectFailure { try await fixture.target.validateFormPreservation(binding) }
        await expectFailure { try await fixture.apply(contract) }
        XCTAssertEqual(fixture.native.server.count("/input"), 1)
    }

    func testScalarInputViolationWithholdsTheUnsentChangeTail() async throws {
        let fixture = try await NativeFormPreservationFixture(scalar: true,
            inputHandler: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        _ = try await fixture.prepare()
        let contract = try fixture.contract()
        await expectFailure { try await fixture.apply(contract) }
        try await fixture.native.wait { fixture.native.server.count("/input") == 1 }
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertFalse(dispatched, "Scalar delivery still lacks its change notification")
        await expectFailure { _ = try await fixture.target.finishPendingChange(operationID: contract.steps[0].id) }
        XCTAssertEqual(fixture.native.server.count("/input"), 1)
        XCTAssertEqual(fixture.native.server.count("/change"), 0)
    }

    func testScalarChangeViolationKeepsTheCompletedReceipt() async throws {
        let fixture = try await NativeFormPreservationFixture(scalar: true,
            changeHandler: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        await expectFailure { try await fixture.apply(contract) }
        try await fixture.native.wait { fixture.native.server.count("/change") == 1 }
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertTrue(dispatched)
        await expectFailure { try await fixture.target.validateFormPreservation(binding) }
        let finishedAgain = try await fixture.target.finishPendingChange(operationID: contract.steps[0].id)
        XCTAssertTrue(finishedAgain)
        XCTAssertEqual(fixture.native.server.count("/input"), 1)
        XCTAssertEqual(fixture.native.server.count("/change"), 1)
    }

    func testObservedPropertyViolationStaysInvalidAfterRestoration() async throws {
        let fixture = try await NativeFormPreservationFixture(
            inputHandler: "document.getElementById('reference').value='changed';",
            mutation: "document.getElementById('reference').value='keep';")
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        await expectFailure { try await fixture.apply(contract) }
        try await fixture.releaseMutation()
        await expectFailure { try await fixture.target.validateFormPreservation(binding) }
        let fresh = try await fixture.native.browser.observePage(document: fixture.native.document)
        await expectFailure {
            _ = try await fixture.target.prepareFormPreservation(controlIDs: binding.controlIDs, page: fresh,
                scopeDigest: ComputerUseTaskContract.digest(["replacement-purpose"]))
        }
    }

    func testReplacementReinsertionAndRestoredLabelTextRetireOriginalBindings() async throws {
        for mutation in [
            "e.replaceWith(e.cloneNode(true));",
            "const p=e.parentNode; e.remove(); p.appendChild(e);",
            "const label=e.parentNode; label.firstChild.textContent='Changed'; label.firstChild.textContent='Reference';",
            "const label=e.parentNode; label.firstChild.replaceWith(document.createTextNode('Reference'));"
        ] {
            let fixture = try await NativeFormPreservationFixture(mutation: "const e=document.getElementById('reference'); " + mutation)
            defer { fixture.close() }
            let binding = try await fixture.prepare()
            try await fixture.releaseMutation()
            await expectFailure { try await fixture.target.validateFormPreservation(binding) }
        }
    }

    func testRestoredDeclaredAttributesAndReplacedOptionsInvalidatePredicates() async throws {
        let cases = [
            ("<div id=setting role=switch aria-label=Setting aria-checked=false></div>",
             "e.setAttribute('aria-checked','true'); e.setAttribute('aria-checked','false');"),
            ("<div id=setting role=switch aria-label=Setting aria-checked=false></div>",
             "e.setAttribute('aria-describedby','extra'); e.removeAttribute('aria-describedby');"),
            ("<label>Setting<select id=setting disabled><option selected>First</option><option>Second</option></select></label>",
             "e.options[0].replaceWith(e.options[0].cloneNode(true));")
        ]
        for (settings, mutation) in cases {
            let fixture = try await NativeFormPreservationFixture(settings: settings,
                mutation: "const e=document.getElementById('setting'); " + mutation)
            defer { fixture.close() }
            let binding = try await fixture.prepare(["Setting"])
            try await fixture.releaseMutation()
            await expectFailure { try await fixture.target.validateFormPreservation(binding) }
        }
    }

    func testRepeatedPreparationIsStableAndExtensionsCannotDropOriginalControls() async throws {
        let fixture = try await NativeFormPreservationFixture(settings: NativeFormPreservationFixture.reference +
            "<label>Direct<input type=checkbox checked></label>")
        defer { fixture.close() }
        let first = try await fixture.prepare(), repeated = try await fixture.prepare()
        XCTAssertEqual(first, repeated)
        let extended = try await fixture.prepare(["Reference","Direct"], purpose: "extended")
        XCTAssertNotEqual(first.id, extended.id)
        XCTAssertNotEqual(first.digest, extended.digest)
        await expectFailure { _ = try await fixture.prepare(["Direct"], purpose: "drop-original") }
        let old = try await fixture.native.browser.callDOM(.prepareFormPreservation,
            arguments: ["documentID":first.documentID,"inputLedgerID":first.inputLedgerID,
                "snapshotID":fixture.page.page.id,"scopeDigest":first.scopeDigest,"controlIDs":first.controlIDs], document: fixture.native.document)
        XCTAssertEqual(old.status, "constraint-changed")
        await expectFailure { try await fixture.target.validateFormPreservation(first) }
        try await fixture.target.validateFormPreservation(extended)
    }

    func testWritableAndProtectedControlsCannotBeSmuggledIntoPrivatePreservation() async throws {
        let fixture = try await NativeFormPreservationFixture(settings: """
            <label>Tickets<input type=number value=2></label>
            <label>Fare<select><option selected>Standard</option></select></label>
            <div role=slider aria-label='Account number' aria-valuenow=12345678></div>
            """)
        defer { fixture.close() }
        for label in ["Query","Tickets","Fare","Account number"] {
            let control = try XCTUnwrap(fixture.page.page.controls.first { $0.label == label })
            XCTAssertFalse(ComputerUseBrowserFormPreservation.allows(control), label)
            await expectFailure { _ = try await fixture.prepare([label]) }
        }
        XCTAssertNil(fixture.target.formPreservation)
    }

    func testAuthenticationAfterInputBlocksPrivateObservationButRetainsReceipt() async throws {
        let fixture = try await NativeFormPreservationFixture(inputHandler:
            "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');")
        defer { fixture.close() }
        let binding = try await fixture.prepare(), contract = try fixture.contract()
        await expectFailure { try await fixture.apply(contract) }
        let dispatched = try await fixture.target.didDispatchInput(operationID: contract.steps[0].id)
        XCTAssertTrue(dispatched)
        let current = try await fixture.native.browser.callDOM(.validateFormPreservation,
            arguments: ["documentID":binding.documentID,"inputLedgerID":binding.inputLedgerID,
                "preservationID":binding.id], document: fixture.native.document)
        XCTAssertEqual(current.status, "authentication-required")
        XCTAssertNil(current.fields); XCTAssertNil(current.page); XCTAssertNil(current.formPreservation)
    }

    func testRediscoveryAndUnintegratedClarificationCannotClearTheGuard() async throws {
        let fixture = try await NativeFormPreservationFixture()
        defer { fixture.close() }
        let binding = try await fixture.prepare()
        let rediscovery = try await fixture.native.browser.callDOM(.fields, arguments: [:], document: fixture.native.document)
        XCTAssertEqual(rediscovery.status, "unsupported")
        XCTAssertNil(rediscovery.fields)
        XCTAssertThrowsError(try fixture.target.transferForClarification(taskID: "new-answer"))
        XCTAssertTrue(fixture.native.browser.validate(fixture.native.document), "Reject before transferring the owner")
        try await fixture.target.validateFormPreservation(binding)
    }

    func testQueryWithoutFieldRequirementsStillChecksReadonlyPreservation() async throws {
        let fixture = try await NativeFormPreservationFixture(mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let binding = try await fixture.prepare()
        let submitter = try XCTUnwrap(fixture.page.page.controls.first { $0.label == "Search" }?.id)
        let prepared = try await fixture.native.browser.callDOM(.prepareFormQuery,
            arguments: ["documentID":binding.documentID,"snapshotID":fixture.page.page.id,"controlID":submitter], document: fixture.native.document)
        XCTAssertEqual(prepared.status, "form-query-prepared")
        let query = try XCTUnwrap(prepared.formQuery)
        try await fixture.releaseMutation()
        let validation = try await fixture.native.browser.callDOM(.validateFormQuery,
            arguments: ["documentID":binding.documentID,"snapshotID":fixture.page.page.id,
                "controlID":submitter,"queryID":query.id], document: fixture.native.document)
        XCTAssertEqual(validation.status, "constraint-changed")
        let another = try await fixture.native.browser.callDOM(.prepareFormQuery,
            arguments: ["documentID":binding.documentID,"snapshotID":fixture.page.page.id,"controlID":submitter], document: fixture.native.document)
        XCTAssertEqual(another.status, "constraint-changed")
        XCTAssertNil(another.formQuery)
        XCTAssertEqual(fixture.native.server.count("/results"), 0)
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("The original preservation obligation must remain enforced", file: file, line: line) }
        catch { }
    }
}

@MainActor
private final class NativeFormPreservationFixture {
    static let reference = "<label>Reference<input id=reference readonly value=keep></label>"
    let native: ControlStateFixture
    let target: ComputerUseBrowserTextTarget
    let page: ComputerUseBrowserPageEvidence
    let fields: [ComputerUseTextField]
    let initial: ComputerUseTextSnapshot
    let scalar: Bool

    init(settings: String? = nil, scalar: Bool = false,
         inputHandler: String = "", changeHandler: String = "", mutation: String = "") async throws {
        self.scalar = scalar
        native = try await ControlStateFixture(body: """
            <form id=search action=/results method=get>
              <label>Query<input id=query name=q \(scalar ? "type=number value=10" : "value=old")></label>
              <button type=submit>Search</button>
            </form>\(settings ?? Self.reference)
            <script>
            const q=document.getElementById('query');
            q.addEventListener('input', () => { fetch('/input'); \(inputHandler) });
            q.addEventListener('change', () => { fetch('/change'); \(changeHandler) });
            fetch('/signal').then(() => { \(mutation) fetch('/changed'); });
            </script>
            """, heldSignal: true)
        target = .init(browser: native.browser, document: native.document, requiresFrontmost: false)
        do {
            page = try await native.browser.observePage(document: native.document)
            let query = try XCTUnwrap(page.page.controls.first { $0.label == "Query" })
            let form = try XCTUnwrap(query.form?.id)
            fields = try await target.fields(in: form, page: page, preserving: [], selecting: [query.id])
            initial = try XCTUnwrap(fields.first?.snapshot)
        } catch { native.close(); throw error }
    }

    func prepare(_ labels: [String] = ["Reference"], purpose: String = "original-preservation") async throws -> ComputerUseBrowserFormPreservation {
        let ids = try labels.map { label in try XCTUnwrap(page.page.controls.first { $0.label == label }?.id) }
        return try await target.prepareFormPreservation(controlIDs: ids, page: page, scopeDigest: ComputerUseTaskContract.digest([purpose]))
    }
    func contract() throws -> ComputerUseTextTaskContract {
        try .init(taskID: "native-preservation-fixture", prompt: "Change Query and leave the setting unchanged", fields: fields,
            edits: [.init(targetID: initial.targetID, mode: .replaceAll, text: scalar ? "11" : "new")])
    }
    func apply(_ contract: ComputerUseTextTaskContract) async throws {
        try await target.apply(.init(targetID: initial.targetID, mode: .replaceAll, text: contract.steps[0].payload),
            expected: initial, operationID: contract.steps[0].id)
    }
    func releaseMutation() async throws {
        try await native.wait { native.server.count("/signal") == 1 }
        native.server.releaseHeldResponses()
        try await native.wait { native.server.count("/changed") == 1 }
    }
    func close() { native.close() }
}

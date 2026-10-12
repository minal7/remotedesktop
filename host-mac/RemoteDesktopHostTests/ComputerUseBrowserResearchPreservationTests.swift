import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Authored decisions and native fixture coverage, prepared but not executed.
@MainActor
final class ComputerUseBrowserResearchPreservationTests: XCTestCase {

    func testUnusedFormStructureRequiresCompleteMetadataAndTracksNativeMembershipOnly() {
        typealias Structure = ComputerUseBrowserUnusedFormIntent.FormStructure
        func page(id: String = "field1", label: String = "Query", formID: String = "form1", omitted: Bool = false, unavailableValues: Bool = false, truncated: Bool = false) -> ComputerUseBrowserPageSnapshot {
            let form = ComputerUseBrowserPageSnapshot.Control.Form(id: formID, method: "get", action: "https://private.test/search", target: "", encoding: "application/x-www-form-urlencoded", noValidate: false)
            let control = ComputerUseBrowserPageSnapshot.Control(id: id, containerID: "container", label: label, kind: "text", name: "query",
                disabled: false, readOnly: false, required: false, multiple: false, constraints: [:], options: [], form: form)
            return .init(id: "snapshot", texts: [], links: [], controls: [control], truncated: truncated,
                omittedEmbeddedContent: false, omittedControls: omitted || unavailableValues, omittedControlMetadata: omitted)
        }
        let original = Structure(page())
        XCTAssertNotNil(original); XCTAssertEqual(original?.controlsByForm, ["form1":Set(["field1"])])
        XCTAssertEqual(original, Structure(page(label: "Changed label")))
        XCTAssertEqual(original, Structure(page(unavailableValues: true)))
        XCTAssertNotEqual(original, Structure(page(id: "field2")))
        XCTAssertNotEqual(original, Structure(page(formID: "form2")))
        XCTAssertNil(Structure(page(omitted: true))); XCTAssertNil(Structure(page(truncated: true)))
    }

    func testInitialReadAbsenceDoesNotTreatPendingOrOrdinaryFailuresAsUnobserved() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        for failure in [ComputerUseBrowserError.authenticationRequired, .pageChanged, .unsupportedDocument] {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
            XCTAssertTrue(capture.initialFieldsWereNotObserved)
            try capture.begin(command: .formFields, arguments: [:], document: fixture.document)
            XCTAssertFalse(capture.initialFieldsWereNotObserved, "A pending native read is not absence")
            XCTAssertNil(capture.completedInitialFieldRead); XCTAssertTrue(capture.hasPendingRead)
            capture.finish(.failure(failure))
            XCTAssertEqual(capture.initialFieldsWereNotObserved, failure == .authenticationRequired)
            XCTAssertNil(capture.completedInitialFieldRead); XCTAssertFalse(capture.hasPendingRead)
            XCTAssertTrue(capture.didStart, "Inspecting absence must not erase the original callback")
        }
        let cancelled = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try cancelled.begin(command: .formFields, arguments: [:], document: fixture.document)
        cancelled.finish(.failure(CancellationError()))
        XCTAssertFalse(cancelled.initialFieldsWereNotObserved)
        let revision = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        XCTAssertFalse(revision.initialFieldsWereNotObserved, "An inherited revision cannot release the initial frame")
        let completed = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try completed.begin(command: .formFields, arguments: [:], document: fixture.document)
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"ok", "documentID":String(repeating: "a", count: 32), "inputLedgerID":String(repeating: "b", count: 32),
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .formFields)
        completed.finish(.success(reply))
        XCTAssertFalse(completed.initialFieldsWereNotObserved)
        XCTAssertEqual(completed.completedInitialFieldRead?.documentID, String(repeating: "a", count: 32))
        XCTAssertEqual(completed.completedInitialFieldRead?.ledgerID, String(repeating: "b", count: 32))
    }

    func testAdditiveNativeScopeStillEnforcesEarlierQueryRequirementsAndReceipts() async throws {
        let fixture = try await ControlStateFixture(body: """
            <form action=/filtered><label>Query<input name=q value=old></label><button>Search</button></form>
            <label>Reference<input id=reference readonly value=keep></label><label>Direct<input type=checkbox checked></label>
            <script>fetch('/signal').then(()=>{ document.getElementById('reference').value='changed'; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let page = try await fixture.browser.observePage(document: fixture.document)
        func id(_ label: String) throws -> String { try XCTUnwrap(page.page.controls.first { $0.label == label }?.id) }
        let form = try XCTUnwrap(page.page.controls.first { $0.label == "Query" }?.form?.id)
        let fields = try await fixture.browser.callDOM(.formFields, arguments: ["documentID":page.documentID,
            "snapshotID":page.page.id,"formID":form,"preservedControlIDs":[],"selectedControlIDs":[try id("Query")]], document: fixture.document)
        let field = try XCTUnwrap(fields.fields?.first), ledger = try XCTUnwrap(fields.inputLedgerID)
        func preserve(_ labels: [String], purpose: String) async throws -> ComputerUseBrowserFormPreservation.Reply {
            let reply = try await fixture.browser.callDOM(.prepareFormPreservation, arguments: ["documentID":page.documentID,
                "inputLedgerID":ledger,"snapshotID":page.page.id,"scopeDigest":ComputerUseTaskContract.digest([purpose]),
                "controlIDs":try labels.map(id)], document: fixture.document)
            return try XCTUnwrap(reply.formPreservation)
        }
        let first = try await preserve(["Reference"], purpose: "original")
        let operation = ComputerUseTaskContract.digest(["original-input"])
        let edit = try await fixture.browser.callDOM(.edit, arguments: ["documentID":page.documentID,"id":field.id,
            "operationID":operation,"mode":"replaceAll","payload":"concerts","before":"old","after":"concerts",
            "selectionStart":field.selectionStart,"selectionEnd":field.selectionEnd,"requiredValues":[],"preservationID":first.id], document: fixture.document)
        XCTAssertEqual(edit.status, "attempted")
        let next = try await preserve(["Reference","Direct"], purpose: "added-setting")
        XCTAssertNotEqual(next.id, first.id)
        let requirements: [String: Any] = ["digest":ComputerUseTaskContract.digest(["original-contract"]),"inputOperationIDs":[operation],
            "preservationID":first.id,"fields":[["id":field.id,"value":"concerts","mustSubmit":true] as [String: Any]]]
        let queryArguments: [String: Any] = ["documentID":page.documentID,"snapshotID":page.page.id,"controlID":try id("Search"),"requirements":requirements]
        let query = try await fixture.browser.callDOM(.prepareFormQuery, arguments: queryArguments, document: fixture.document)
        XCTAssertEqual(query.status, "form-query-prepared", "A stronger guard keeps the original required values and receipts")
        var unknownRequirements = requirements; unknownRequirements["preservationID"] = String(repeating: "0", count: 32)
        var unknownQuery = queryArguments; unknownQuery["requirements"] = unknownRequirements
        let unknown = try await fixture.browser.callDOM(.prepareFormQuery, arguments: unknownQuery, document: fixture.document)
        XCTAssertEqual(unknown.status, "stale", "An unrelated guard cannot stand in for an ancestor")
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let changed = try await fixture.browser.callDOM(.prepareFormQuery, arguments: queryArguments, document: fixture.document)
        XCTAssertEqual(changed.status, "constraint-changed")
        let history = try await fixture.browser.callDOM(.receipt, arguments: ["documentID":page.documentID,"operationID":operation], document: fixture.document)
        XCTAssertEqual(history.status, "dispatched")
    }

    func testPrivateReadCaptureRejectsEffectsAndChangedArguments() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        for command in [ComputerUseBrowserDOMCommand.edit, .continueUnsentInput, .openPopup, .selectOption, .scrollViewport, .validateFormState] {
            XCTAssertThrowsError(try ComputerUseBrowserDOMReadCapture(command: command, document: fixture.document))
        }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        let arguments: [String: Any] = ["snapshotID":"first","selectedControlIDs":["c1"]]
        try capture.begin(command: .formFields, arguments: arguments, document: fixture.document)
        capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
            #"{"status":"ok","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#, command: .formFields)))
        XCTAssertNotNil(try capture.retainedReply(command: .formFields,
            arguments: ["snapshotID":"new-nonce","selectedControlIDs":["c1"]], document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .formFields,
            arguments: ["snapshotID":"new-nonce","selectedControlIDs":["c2"]], document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .bindPageFields, arguments: arguments, document: fixture.document))
        XCTAssertFalse(String(describing: capture).contains("c1"))
    }

    func testUnknownReadFailureCannotBeRetriedAsAnAbsentObservation() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try capture.begin(command: .formFields, arguments: [:], document: fixture.document)
        capture.finish(.failure(ComputerUseBrowserError.pageChanged))
        XCTAssertThrowsError(try capture.retainedReply(command: .formFields, arguments: [:], document: fixture.document))
        XCTAssertTrue(capture.didStart)
        XCTAssertThrowsError(try capture.begin(command: .formFields, arguments: [:], document: fixture.document))
    }

    func testCapturedExtensionCannotChangeItsEarlierRequirementsOrRepairableObjects() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .extendFormFields, document: fixture.document)
        let original: [String: Any] = ["snapshotID":"first", "selectedControlIDs":["c2"],
            "requirements":["digest":"original-requirements", "preservationID":"original-preservation"], "repairableFieldIDs":["f1"]]
        try capture.begin(command: .extendFormFields, arguments: original, document: fixture.document)
        capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
            #"{"status":"ok","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#, command: .extendFormFields)))
        var refreshed = original; refreshed["snapshotID"] = "new-observation"
        XCTAssertNotNil(try capture.retainedReply(command: .extendFormFields, arguments: refreshed, document: fixture.document))
        for replacement: [String: Any] in [
            ["requirements":["digest":"different-requirements", "preservationID":"original-preservation"]],
            ["requirements":["digest":"original-requirements", "preservationID":"different-preservation"]],
            ["repairableFieldIDs":["f2"]], ["selectedControlIDs":["c3"]]
        ] {
            let changed = refreshed.merging(replacement) { _, new in new }
            XCTAssertThrowsError(try capture.retainedReply(command: .extendFormFields, arguments: changed, document: fixture.document))
        }
    }

    func testUncapturedRevisionReplyRequiresItsExactCommandAndEmptyPayload() throws {
        let body: [String: Any] = ["status":"revision-not-captured", "documentID":String(repeating: "a", count: 32),
            "inputLedgerID":String(repeating: "b", count: 32), "uncapturedRevisionID":String(repeating: "c", count: 64)]
        let source = try ResearchAnswerFixture.json(body)
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: .reviseFormFields).status, "revision-not-captured")
        for command in [ComputerUseBrowserDOMCommand.formFields, .extendFormFields, .inspectFormRequirements, .verifyFormState, .edit] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: command))
        }
        for replacement: [String: Any] in [["status":"stale"], ["status":"authentication-required"],
            ["uncapturedRevisionID":"bad"], ["uncapturedRevisionID":NSNull()], ["inputLedgerID":"bad"],
            ["inputLedgerID":NSNull()], ["fields":[]], ["changedFieldIDs":[]], ["formBindings":[]],
            ["popupControls":[]], ["popupPreservedControls":[]], ["selectionPreservedControls":[]], ["optionSelectionCandidates":[]]] {
            let changed = try ResearchAnswerFixture.json(body.merging(replacement) { _, new in new })
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(changed, command: .reviseFormFields))
        }
    }

    func testUncapturedRevisionWitnessKeepsItsArgumentsAndExactNativeIdentity() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        let arguments: [String: Any] = ["revisionID":revision, "snapshotID":"first", "selectedControlIDs":["c1"]]
        try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document)
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger, "uncapturedRevisionID":revision]), command: .reviseFormFields)
        capture.finish(.success(reply))
        XCTAssertTrue(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: ledger, inputLedgerID: ledger))
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: documentID))
        XCTAssertNotNil(try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["snapshotID":"fresh"]) { _, new in new }, document: fixture.document))
        XCTAssertTrue(capture.didStart)
        XCTAssertThrowsError(try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["selectedControlIDs":["c2"]]) { _, new in new }, document: fixture.document))
        let foreign = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        try foreign.begin(command: .reviseFormFields, arguments: ["revisionID":String(repeating: "d", count: 64)], document: fixture.document)
        foreign.finish(.success(reply))
        XCTAssertFalse(foreign.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
    }

    func testOrdinaryFailedOrCompletedRevisionCannotBecomeAnAbsentCapture() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let absent = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger, "uncapturedRevisionID":revision]), command: .reviseFormFields)
        let results: [Result<ComputerUseBrowserDOMReply, Error>] = try [
            .failure(ComputerUseBrowserError.pageChanged), .failure(ComputerUseBrowserError.documentUnresponsive),
            .success(ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
                "status":"stale", "documentID":documentID, "inputLedgerID":ledger]), command: .reviseFormFields)),
            .success(ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
                "status":"ok", "documentID":documentID, "inputLedgerID":ledger, "fields":[]]), command: .reviseFormFields))]
        for result in results {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
            try capture.begin(command: .reviseFormFields, arguments: ["revisionID":revision], document: fixture.document)
            capture.finish(result); capture.finish(.success(absent))
            XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
            XCTAssertTrue(capture.didStart)
        }
    }

    func testOnlyAnEmptyAuthenticationReplyCanReleaseAnUnobservedCapture() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .prepareFormPreservation, document: fixture.document)
        try capture.begin(command: .prepareFormPreservation, arguments: [:], document: fixture.document)
        let empty = #"{"status":"authentication-required","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        let fields = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try fields.begin(command: .formFields, arguments: [:], document: fixture.document)
        fields.finish(Result { try ComputerUseOwnedBrowser.decodeDOMReply(empty, command: .formFields) })
        XCTAssertTrue(fields.initialFieldsWereNotObserved)
        XCTAssertTrue(fields.didStart, "The absence predicate preserves the validated terminal reply")
        capture.finish(Result { try ComputerUseOwnedBrowser.decodeDOMReply(empty, command: .prepareFormPreservation) })
        XCTAssertNil(try capture.retainedReply(command: .prepareFormPreservation, arguments: [:], document: fixture.document))
        XCTAssertFalse(capture.didStart)
        let malformed = try ResearchAnswerFixture.json(["status":"authentication-required","documentID":String(repeating: "a", count: 32),
            "formPreservation":["id":String(repeating: "b", count: 32),"scopeDigest":String(repeating: "c", count: 64),
                "controlIDs":["c1"],"states":[["controlID":"c1","kind":"text","value":"private"]]]])
        for command in [ComputerUseBrowserDOMCommand.prepareFormPreservation, .formFields] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(malformed, command: command)) { error in
                XCTAssertEqual(error as? ComputerUseBrowserError, .unsupportedDocument)
            }
        }
    }

    func testRevisionHistoryReplyRequiresExactIdentityAndHistoricalFields() throws {
        let body: [String: Any] = ["status":"ok", "documentID":String(repeating: "a", count: 32),
            "inputLedgerID":String(repeating: "b", count: 32), "recoveredRevisionID":String(repeating: "c", count: 64),
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]
        let source = try ResearchAnswerFixture.json(body)
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: .inspectPreparedRevision).fields?.first?.value, "old")
        for command in [ComputerUseBrowserDOMCommand.reviseFormFields, .formFields, .extendFormFields, .inspectFormRequirements, .edit] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: command))
        }
        for replacement: [String: Any] in [["recoveredRevisionID":NSNull()], ["recoveredRevisionID":"bad"],
            ["inputLedgerID":NSNull()], ["inputLedgerID":"bad"], ["fields":[]], ["fields":NSNull()],
            ["status":"stale"], ["status":"authentication-required"], ["changedFieldIDs":[]], ["formBindings":[]],
            ["popupControls":[]], ["selectionPreservedControls":[]], ["uncapturedRevisionID":String(repeating: "c", count: 64)]] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(
                body.merging(replacement) { _, new in new }), command: .inspectPreparedRevision))
        }
        let absent = body.merging(["status":"revision-not-captured", "fields":NSNull(),
            "uncapturedRevisionID":String(repeating: "c", count: 64)]) { _, new in new }
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(absent), command: .inspectPreparedRevision).status, "revision-not-captured")
        XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(
            absent.merging(["uncapturedRevisionID":String(repeating: "d", count: 64)]) { _, new in new }), command: .inspectPreparedRevision))
    }

    func testFailedRevisionKeepsItsOriginalAttemptWhenHistoryIsReconciled() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let arguments: [String: Any] = ["revisionID":revision, "snapshotID":"first", "selectedControlIDs":["c1"]]
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document)
        capture.finish(.failure(ComputerUseBrowserError.pageChanged))
        XCTAssertTrue(try capture.requiresRevisionReconciliation(arguments: arguments, document: fixture.document))
        let changed = arguments.merging(["selectedControlIDs":["c2"]]) { _, new in new }
        XCTAssertThrowsError(try capture.requiresRevisionReconciliation(arguments: changed, document: fixture.document))
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"ok", "documentID":documentID, "inputLedgerID":ledger, "recoveredRevisionID":revision,
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .inspectPreparedRevision)
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: changed, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: documentID))
        try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger)
        XCTAssertFalse(capture.needsRevisionReconciliation); XCTAssertTrue(capture.didStart)
        capture.finish(.failure(ComputerUseBrowserError.closed))
        let retained = try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["snapshotID":"fresh"]) { _, new in new }, document: fixture.document)
        XCTAssertEqual(retained?.fields?.first?.value, "old")
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document))
    }

    func testRevisionHistoryCannotOverwritePendingSuccessfulOrAuthenticationCaptures() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let arguments: [String: Any] = ["revisionID":revision]
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger,
            "uncapturedRevisionID":revision, "recoveredRevisionID":revision]), command: .inspectPreparedRevision)
        for state in ["unstarted","pending","stale","completed","authentication"] {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
            if state != "unstarted" { try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document) }
            if state == "stale" { capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
                ResearchAnswerFixture.json(["status":"stale", "documentID":documentID]), command: .reviseFormFields))) }
            if state == "completed" { capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
                ResearchAnswerFixture.json(["status":"ok", "documentID":documentID, "inputLedgerID":ledger,
                    "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .reviseFormFields))) }
            if state == "authentication" { capture.finish(.failure(ComputerUseBrowserError.authenticationRequired)) }
            XCTAssertFalse(capture.needsRevisionReconciliation)
            XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        }
    }

    func testFormStateReplyOwnershipAndFreshValidationCannotBeBypassed() throws {
        let payload: [String: Any] = ["id":String(repeating: "b", count: 32),"planDigest":String(repeating: "c", count: 64)]
        let base: [String: Any] = ["status":"form-state-verified","documentID":String(repeating: "a", count: 32),"formStateProof":payload]
        let content = try ResearchAnswerFixture.json(base)
        XCTAssertNotNil(try ComputerUseOwnedBrowser.decodeDOMReply(content, command: .verifyFormState).formStateProof)
        for command in [ComputerUseBrowserDOMCommand.edit, .formFields, .prepareFormQuery, .validateFormState] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(content, command: command))
        }
        for extra: [String: Any] in [["status":"authentication-required"],["fields":[]],["changedFieldIDs":[]]] {
            let invalid = try ResearchAnswerFixture.json(base.merging(extra) { _, new in new })
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(invalid, command: .verifyFormState))
        }
    }

    private func mixedContent(_ input: ComputerUseBrowserResearchFormInput, order: [String]) throws -> String {
        let aliases = try Dictionary(uniqueKeysWithValues: input.editableFieldAliases.map { (try input.field(for: $0).control.label,$0) })
        let edits: [[String: Any]] = try order.map { label in
            let alias = try XCTUnwrap(aliases[label]), field = try input.field(for: alias)
            if label == "Category" {
                let choice = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
                return ["field":alias,"choice":choice.id,"requirement":0]
            }
            return ["field":alias,"terms":[["requirement":0,"text":label == "City" ? "Seattle" : "concerts"]]]
        }
        var body: [String: Any] = ["edits":edits,"preserve":[]]
        if !input.pendingEditAliases.isEmpty {
            let pending = try XCTUnwrap(input.previous?.pendingEdits)
            body["resume"] = try zip(input.pendingEditAliases, pending).map { id, edit in
                ["pending":id,"field":try XCTUnwrap(aliases[edit.label])]
            }
        }
        return try ResearchAnswerFixture.json(body)
    }

    /// Execute the actual native initial revision, then inject a terminal
    /// callback failure into its host capture instead of delivering the result.
    /// The request mirrors the v1 physical preparation fixture, with no repair.

    private func answerPreparedQuestion(_ owner: ComputerUseBrowserResearchTask, input: ComputerUseBrowserResearchFormInput) throws -> ComputerUseBrowserGoalInput {
        let question = try owner.issueQuestion(topic: .date, requirementIDs: [input.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        return try owner.answerQuestion(questionID: question.id, answerTaskID: "first-answer", answer: "Tomorrow.",
            controllerID: "phone", controllerSessionID: "session")
    }

    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.editableFieldAliases.first), field = try input.field(for: alias)
        XCTAssertEqual(field.control.label, "Category")
        let choice = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"choice":choice.id,"requirement":0]],"preserve":[]])
    }

    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.editableFieldAliases.first)
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
    }
    private func forgedBinding(_ input: ComputerUseBrowserResearchFormInput, value: String, purpose: String? = nil) throws -> ComputerUseBrowserFormPreservation {
        let binding = try XCTUnwrap(input.nativePreservation), id = try XCTUnwrap(binding.controlIDs.first)
        let state = ComputerUseBrowserControlState(controlID: id, kind: .text, value: value, selectedOptionIDs: nil, checked: nil, indeterminate: nil)
        return try .init(reply: .init(id: binding.id, scopeDigest: purpose ?? binding.scopeDigest, controlIDs: binding.controlIDs, states: [state]),
            evidence: input.evidence.page, inputLedgerID: binding.inputLedgerID, scopeDigest: purpose ?? binding.scopeDigest, controlIDs: binding.controlIDs)
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Preservation must remain enforced", file: file, line: line) } catch { }
    }
}

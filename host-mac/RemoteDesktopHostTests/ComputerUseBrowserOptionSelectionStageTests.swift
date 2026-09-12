import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared journal/native boundary cases. The ordinary research owner and
/// planner do not yet offer option selection; no provider/model claim follows.
@MainActor
final class ComputerUseBrowserOptionSelectionStageTests: XCTestCase {
    func testContractFreezesObservedValuesAndMeaningWithoutWritingThemToTheJournal() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        let page = target.intent.evidence.page, ids = [target.intent.controlID] + target.intent.observedPreservedControlIDs
        let original = try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: ids, page: page)
        XCTAssertEqual(original, target.intent.baselineDigest)
        let dateID = try XCTUnwrap(target.intent.observedPreservedControlIDs.first)
        for change in ["2026-09-21", ""] {
            let states = page.controlStates.map { state in
                state.controlID == dateID ? ComputerUseBrowserControlState(controlID: dateID, kind: .scalar,
                    value: change, selectedOptionIDs: nil, checked: nil, indeterminate: nil) : state
            }
            let changed = copy(page, states: states)
            XCTAssertEqual(changed.id, page.id)
            XCTAssertNotEqual(try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: ids, page: changed), original)
        }
        let ownerState = try XCTUnwrap(page.controlStates.first { $0.controlID == target.intent.controlID })
        let alteredMeaning = try XCTUnwrap(ownerState.value).replacingOccurrences(of: "Admission conditions", with: "Different conditions")
        let changedStates = page.controlStates.map { state in
            state.controlID == ownerState.controlID ? ComputerUseBrowserControlState(controlID: ownerState.controlID,
                kind: .composite, value: alteredMeaning, selectedOptionIDs: nil, checked: nil, indeterminate: nil) : state
        }
        XCTAssertNotEqual(try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: ids, page: copy(page, states: changedStates)), original)
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        for binding in [
            ComputerUseBrowserOptionSelectionBinding(id: "bad", controlID: target.intent.controlID, optionID: target.intent.optionID, needsDispatch: true),
            .init(id: target.binding.id, controlID: "c999", optionID: target.intent.optionID, needsDispatch: true),
            .init(id: target.binding.id, controlID: target.intent.controlID, optionID: "o999", needsDispatch: true),
            .init(id: target.binding.id, controlID: target.intent.controlID, optionID: target.intent.optionID, needsDispatch: false)] {
            XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionStage(target: .init(intent: target.intent, binding: binding),
                sequence: 0, browser: fixture.browser, journalDirectory: directory))
        }
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
        _ = try await stage.run(checkCurrent: {})
        let saved = try journal(stage, directory), encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        for value in ["2026-09-20", "General admission", "Admission conditions", "privateUnscoped", "Find concerts", target.binding.id] {
            XCTAssertFalse(encoded.contains(value))
        }
        XCTAssertEqual(stage.contract.steps[0].operation.capabilityID, "browser.selectOption")
        XCTAssertEqual(saved.statuses, [.verified])
    }

    func testAttemptPrecedesTheEffectAndAlreadySelectedObservationDoesNotClick() async throws {
        for alreadySelected in [false, true] {
            let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
            defer { fixture.close() }
            let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture, first: alreadySelected))
            var reference: ComputerUseBrowserOptionSelectionStage?, boundaries = 0
            let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
                journalDirectory: directory, beforeDispatch: {
                    boundaries += 1
                    let stage = try XCTUnwrap(reference), saved = try self.journal(stage, directory)
                    XCTAssertEqual(saved.statuses, [.attempted]); XCTAssertEqual(saved.contractDigest, stage.contract.contractDigest)
                    XCTAssertEqual(fixture.server.count("/chosen"), 0)
                })
            reference = stage; defer { reference = nil }
            let receipt = try await stage.run(checkCurrent: {})
            XCTAssertEqual(receipt.didDispatch, !alreadySelected)
            XCTAssertEqual(receipt.preservedControlIDs, target.intent.observedPreservedControlIDs)
            let repeated = try await stage.run(checkCurrent: {})
            XCTAssertEqual(repeated, receipt); XCTAssertEqual(boundaries, 1)
            if !alreadySelected { try await fixture.wait { fixture.server.count("/chosen") == 1 } }
            let retired = try await stage.retireUnsent(checkCurrent: {})
            XCTAssertNil(retired); XCTAssertEqual(fixture.server.count("/chosen"), alreadySelected ? 0 : 1)
            XCTAssertEqual(try journal(stage, directory).statuses, [.verified])
        }
    }

    func testCancellationBeforeNativeDispatchContinuesOnlyTheOriginalAttempt() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        var boundaries = 0
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, beforeDispatch: { boundaries += 1; throw CancellationError() })
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Cancellation before native dispatch cannot click") }
        catch { XCTAssertTrue(error is CancellationError) }
        let before = try journal(stage, directory)
        XCTAssertEqual(before.statuses, [.attempted]); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        let replacement = try stage.reopened { try .init(directory: $0) }; stage.retire()
        XCTAssertEqual(replacement.target, target); XCTAssertEqual(replacement.operationID, stage.operationID)
        let receipt = try await replacement.run(checkCurrent: {})
        XCTAssertEqual(receipt.operationID, stage.operationID); XCTAssertEqual(boundaries, 1)
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
        let after = try journal(replacement, directory)
        XCTAssertEqual(after.contractDigest, before.contractDigest); XCTAssertEqual(after.statuses, [.verified])
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Retired runner cannot resume") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .retired) }
    }

    func testCancellationJoinsPreflightDispatchAndReceiptBeforeReleasingTheLease() async throws {
        for boundary: ComputerUseBrowserDOMCommand in [.validateOptionSelection, .selectOption, .optionSelectionReceipt] {
            let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
            var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
            let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(), domScriptDidDispatch: { onCommand?($0) })
            defer { fixture.close() }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
            let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
            var cancel: (() -> Void)?, intercepted = false, excluded = false
            onCommand = { command in
                guard command == boundary else { return }
                intercepted = true; onCommand = nil
                do {
                    let other = try ComputerUseTaskJournalStore(directory: directory), saved = try other.load(taskID: stage.contract.taskID)
                    let lease = try other.acquireExecution(taskID: stage.contract.taskID, expected: saved)
                    lease.release(); XCTFail("Another runner cannot acquire the in-flight stage")
                } catch { excluded = error as? ComputerUseTaskJournalStore.StoreError == .busy }
                do {
                    _ = try stage.reopened { try .init(directory: $0) }
                    XCTFail("An in-flight stage cannot be reopened")
                } catch {
                    XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .busy)
                }
                cancel?()
            }
            let running = Task { try await stage.run(checkCurrent: {}) }; cancel = { running.cancel() }
            do { _ = try await running.value; XCTFail("A cancelled caller cannot publish completion") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancel = nil; onCommand = nil
            XCTAssertTrue(intercepted); XCTAssertTrue(excluded)
            // This acquisition refuses pending native callbacks. No extra wait
            // may hide a lease released before the stage joined its DOM work.
            _ = try fixture.browser.acquireCurrentDocument(taskID: fixture.document.taskID)
            let other = try ComputerUseTaskJournalStore(directory: directory), saved = try other.load(taskID: stage.contract.taskID)
            let lease = try other.acquireExecution(taskID: stage.contract.taskID, expected: saved); lease.release()
            if boundary == .validateOptionSelection { XCTAssertNil(saved); XCTAssertEqual(fixture.server.count("/chosen"), 0) }
            else {
                XCTAssertEqual(saved?.statuses, [.attempted])
                try await fixture.wait { fixture.server.count("/chosen") == 1 }
                try await Task.sleep(for: .milliseconds(2100))
            }
            let receipt = try await stage.run(checkCurrent: {})
            XCTAssertEqual(receipt.operationID, stage.operationID)
            try await fixture.wait { fixture.server.count("/chosen") == 1 }
            XCTAssertEqual(try journal(stage, directory).statuses, [.verified])
        }
    }

    func testFailedAttemptWriteRequiresAnExactFreshStoreAndRejectsAReboundChoice() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        let first = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, makeStore: { try .init(directory: $0, afterReplacement: { throw SelectionStageWriteFailure.interrupted }) })
        do { _ = try await first.run(checkCurrent: {}); XCTFail("A failed attempt write cannot dispatch") }
        catch { XCTAssertTrue(error is SelectionStageWriteFailure) }
        let before = try journal(first, directory)
        XCTAssertEqual(before.statuses, [.attempted]); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        let graph = try ResearchAnswerFixture.object(Data(XCTUnwrap(target.intent.evidence.page.controlStates.first { $0.controlID == target.intent.controlID }?.value).utf8))
        let option = try XCTUnwrap((graph["options"] as? [[String: Any]])?.first?["id"] as? String)
        let reboundIntent = try ComputerUseBrowserOptionSelectionIntent(interpretation: target.intent.interpretation,
            evidence: target.intent.evidence, controlID: target.intent.controlID, optionID: option, requirementIndex: target.intent.requirementIndex)
        let rebound = try await fixture.browser.prepareOptionSelection(reboundIntent)
        XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionStage(target: rebound, sequence: 0, browser: fixture.browser, journalDirectory: directory)) {
            XCTAssertEqual($0 as? ComputerUseTaskExecutionError, .journalMismatch)
        }
        let reopened = try first.reopened { try .init(directory: $0) }; first.retire()
        XCTAssertEqual(reopened.target, target); XCTAssertEqual(reopened.operationID, first.operationID)
        _ = try await reopened.run(checkCurrent: {})
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
        let after = try journal(reopened, directory)
        XCTAssertEqual(after.contractDigest, before.contractDigest); XCTAssertEqual(after.statuses, [.verified])
    }

    func testFailedVerifiedWriteKeepsTheNativeFactButRequiresDurableReconfirmation() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        var writes = 0
        let first = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, makeStore: { try .init(directory: $0, afterReplacement: {
                writes += 1; if writes == 2 { throw SelectionStageWriteFailure.interrupted }
            }) })
        do { _ = try await first.run(checkCurrent: {}); XCTFail("A visible verified replacement is not confirmed durability") }
        catch { XCTAssertTrue(error is SelectionStageWriteFailure) }
        let native = try XCTUnwrap(first.observedReceipt), before = try journal(first, directory)
        XCTAssertEqual(before.statuses, [.verified]); XCTAssertTrue(native.validates(target, operationID: first.operationID))
        do { _ = try await first.run(checkCurrent: {}); XCTFail("The poisoned store cannot keep publishing") }
        catch { XCTAssertTrue(error is ComputerUseTaskJournalStore.StoreError) }
        let reopened = try first.reopened { try .init(directory: $0) }; first.retire()
        XCTAssertEqual(reopened.observedReceipt, native)
        let receipt = try await reopened.run(checkCurrent: {})
        XCTAssertEqual(receipt, native); XCTAssertEqual(try journal(reopened, directory), before)
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
        XCTAssertEqual(writes, 2)
    }

    func testFailedUnsentRetirementRemainsPendingUntilTheExactTombstoneIsReconfirmed() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        var writes = 0
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, beforeDispatch: { throw CancellationError() }, makeStore: { try .init(directory: $0, afterReplacement: {
                writes += 1; if writes == 2 { throw SelectionStageWriteFailure.interrupted }
            }) })
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Expected the retained unsent attempt") }
        catch { XCTAssertTrue(error is CancellationError) }
        let before = try journal(stage, directory)
        do { _ = try await stage.retireUnsent(checkCurrent: {}); XCTFail("Failed retirement durability cannot release planning") }
        catch { XCTAssertTrue(error is SelectionStageWriteFailure) }
        XCTAssertNil(stage.retirementDigest)
        let tombstone = try journal(stage, directory)
        XCTAssertNotNil(tombstone.retirementDigest); XCTAssertEqual(tombstone.statuses, before.statuses)
        let reopened = try stage.reopened { try .init(directory: $0) }; stage.retire()
        do { _ = try await reopened.run(checkCurrent: {}); XCTFail("Reopened retirement is not executable") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .retirementPending) }
        let digest = try await reopened.retireUnsent(checkCurrent: {})
        XCTAssertEqual(digest, tombstone.retirementDigest); XCTAssertEqual(reopened.retirementDigest, digest)
        XCTAssertEqual(try journal(reopened, directory), tombstone)
        do { _ = try await reopened.run(checkCurrent: {}); XCTFail("Durably retired work cannot resume") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .retired) }
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testChangedObservedCriteriaCannotBeRebaselinedByStageReopening() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(extra: "document.getElementById('date').value='2026-09-21';"))
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("An overwritten date cannot confirm selection") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let reopened = try stage.reopened { try .init(directory: $0) }; stage.retire()
        XCTAssertEqual(reopened.target.intent.baselineDigest, target.intent.baselineDigest)
        XCTAssertEqual(reopened.target.intent.evidence.page.controlStates, target.intent.evidence.page.controlStates)
        do { _ = try await reopened.run(checkCurrent: {}); XCTFail("Recovery cannot adopt the changed date") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let retired = try await reopened.retireUnsent(checkCurrent: {})
        XCTAssertNil(retired); XCTAssertNil(reopened.observedReceipt)
        XCTAssertEqual(try journal(reopened, directory).statuses, [.uncertain])
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
    }

    func testChangedUnsentChoiceRetiresItsOriginalContractBeforeFreshPreparation() async throws {
        let change = "const option=document.getElementById('second'); option.replaceWith(option.cloneNode(true));"
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page() + OptionSelectionFixture.signal(change), heldSignal: true)
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, beforeDispatch: {
                try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
            })
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("A replacement option is a different native target") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let before = try journal(stage, directory)
        XCTAssertEqual(before.statuses, [.uncertain]); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        let digest = try await stage.retireUnsent(checkCurrent: {}), after = try journal(stage, directory)
        XCTAssertNotNil(digest); XCTAssertEqual(after.retirementDigest, digest)
        XCTAssertEqual(after.statuses, before.statuses); XCTAssertEqual(after.contractDigest, before.contractDigest)
        let fresh = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionStage(target: fresh, sequence: 0, browser: fixture.browser, journalDirectory: directory)) {
            XCTAssertEqual($0 as? ComputerUseTaskExecutionError, .journalMismatch)
        }
        let next = try ComputerUseBrowserOptionSelectionStage(target: fresh, sequence: 1, browser: fixture.browser, journalDirectory: directory)
        let receipt = try await next.run(checkCurrent: {})
        XCTAssertNotEqual(receipt.operationID, stage.operationID)
        XCTAssertEqual(fresh.intent.interpretation, target.intent.interpretation)
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
    }

    func testLateSelectionCannotRenewTheNativeWindowOrBecomeAnUnsentRetirement() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(handler: """
            fetch('/chosen'); setTimeout(() => { document.getElementById('first').setAttribute('aria-selected','false');
            document.getElementById('second').setAttribute('aria-selected','true'); fetch('/late'); },2300);
            """))
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, confirmationBudget: .zero)
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("An event alone is not a selected option") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let reopened = try stage.reopened { try .init(directory: $0) }; stage.retire()
        try await fixture.wait { fixture.server.count("/late") == 1 }
        do { _ = try await reopened.run(checkCurrent: {}); XCTFail("Recovery cannot restart the native window") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let retired = try await reopened.retireUnsent(checkCurrent: {})
        XCTAssertNil(retired); XCTAssertNil(reopened.observedReceipt)
        XCTAssertEqual(fixture.server.count("/chosen"), 1); XCTAssertEqual(try journal(reopened, directory).statuses, [.uncertain])
    }

    func testAuthenticationBeforeAndAfterTheAttemptKeepsItsTypedHandoffBoundary() async throws {
        let login = "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');"
        for beforeAttempt in [true, false] {
            let body = beforeAttempt ? OptionSelectionFixture.page() + OptionSelectionFixture.signal(login) : OptionSelectionFixture.page(extra: login)
            let fixture = try await ControlStateFixture(body: body, heldSignal: beforeAttempt)
            defer { fixture.close() }
            let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
            let stage = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
            if beforeAttempt {
                try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
            }
            do { _ = try await stage.run(checkCurrent: {}); XCTFail("Authentication must reach manual handoff") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
            let saved = try ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID)
            XCTAssertNil(stage.observedReceipt)
            if beforeAttempt { XCTAssertNil(saved); XCTAssertEqual(fixture.server.count("/chosen"), 0) }
            else {
                XCTAssertEqual(saved?.statuses, [.uncertain])
                let reopened = try stage.reopened { try .init(directory: $0) }; stage.retire()
                do { _ = try await reopened.run(checkCurrent: {}); XCTFail("An attempted selection cannot bypass login on recovery") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
                try await fixture.wait { fixture.server.count("/chosen") == 1 }
            }
        }
    }

    private func copy(_ page: ComputerUseBrowserPageSnapshot, states: [ComputerUseBrowserControlState]) -> ComputerUseBrowserPageSnapshot {
        .init(id: page.id, texts: page.texts, links: page.links, controls: page.controls, truncated: page.truncated,
            omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls, viewport: page.viewport,
            containers: page.containers, omittedStructure: page.omittedStructure, controlStates: states,
            controlStateObserved: page.controlStateObserved, scopedControlIDs: page.scopedControlIDs)
    }
    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("selection-stage-" + UUID().uuidString, isDirectory: true) }
    private func journal(_ stage: ComputerUseBrowserOptionSelectionStage, _ directory: URL) throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID))
    }
}

private enum SelectionStageWriteFailure: Error { case interrupted }

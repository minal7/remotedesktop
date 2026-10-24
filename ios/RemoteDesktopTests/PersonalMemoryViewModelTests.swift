import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemoryViewModelTests: XCTestCase {
    func testDisabledControllerNeverCallsChannel() async throws {
        let channel = MemoryDisplayChannel()
        let model = PersonalMemoryViewModel(enabled: false, channel: channel)
        model.open()
        try await wait { model.state == .unavailable }
        let calls = await channel.commands()
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.records.isEmpty)
    }

    func testEnabledControllerWithoutChannelNeverCallsAnything() async throws {
        let model = PersonalMemoryViewModel(enabled: true, channel: nil)
        model.open(query: "private query")
        model.loadMore()
        model.edit(record: record("missing"), text: "change")
        model.delete(record: record("missing"))
        try await wait { model.state == .unavailable }
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.nextRecordID)
        XCTAssertNil(model.draftText)
    }

    func testCloseInSameTurnAsOpenPreventsQueuedReadDispatch() async throws {
        let channel = MemoryDisplayChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        model.close()
        try await Task.sleep(for: .milliseconds(30))
        let commands = await channel.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testCloseInSameTurnAsEditPreventsQueuedMutationDispatch() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.edit(record: visible, text: "Do not send after close")
        model.close()
        try await Task.sleep(for: .milliseconds(30))
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords])
    }

    func testListAndLoadMoreUsesOneUserRequestedPageAtATime() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: records("fact", count: 20), nextRecordID: "fact-019")))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("fact-020")], nextRecordID: nil)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 20 }
        XCTAssertEqual(model.nextRecordID, "fact-019")
        let firstPageCalls = await channel.commands()
        XCTAssertEqual(firstPageCalls.count, 1)
        model.loadMore()
        try await wait { model.records.count == 21 }
        XCTAssertNil(model.nextRecordID)
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.afterRecordID), [nil, "fact-019"])
    }

    func testSearchStartsAtFirstPageAndReplacesPriorResults() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: records("old", count: 20), nextRecordID: "old-019")))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [record("seat-fact")], nextRecordID: nil)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.nextRecordID == "old-019" }
        model.open(query: "seat")
        try await wait { model.records.map(\.recordID) == ["seat-fact"] }
        XCTAssertEqual(model.query, "seat")
        let commands = await channel.commands()
        XCTAssertEqual(commands.last?.query, "seat")
        XCTAssertNil(commands.last?.afterRecordID)
    }

    func testQueryChangeIgnoresSuspendedOlderPage() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [record("new-result")], nextRecordID: nil)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open(query: "old")
        try await wait { await channel.commands().count == 1 }
        model.open(query: "new")
        try await wait { model.records.map(\.recordID) == ["new-result"] }
        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [record("stale-result")], nextRecordID: nil)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.query, "new")
        XCTAssertEqual(model.records.map(\.recordID), ["new-result"])
    }

    func testCloseAndDisconnectDropLateOwnerTextAndCursor() async throws {
        for close in [true, false] {
            let channel = MemoryDisplayChannel()
            await channel.suspendNext()
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { await channel.commands().count == 1 }
            if close { model.close() } else { model.disconnect() }
            await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .listRecords,
                status: .completed, records: [record("late-private-fact")], nextRecordID: "late-private-fact")))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertNil(model.nextRecordID)
            XCTAssertNil(model.draftText)
            XCTAssertEqual(model.state, .unavailable)
        }
    }

    func testMalformedOrMismatchedReplyFailsClosed() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [record("wrong-operation")], nextRecordID: nil)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.nextRecordID)
    }

    func testUnexpectedRememberKindOnReadReplyFailsClosed() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords,
            rememberKind: .fact, status: .completed)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertTrue(model.records.isEmpty)
    }

    func testQueryChangeCannotCancelAnInFlightEditReceipt() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("fact-a", text: "Edited safely")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        await channel.suspendNext()
        model.edit(record: visible, text: "Edited safely")
        try await wait { await channel.commands().count == 2 }
        model.open(query: "different query")
        try await Task.sleep(for: .milliseconds(30))
        let whileSuspended = await channel.commands()
        XCTAssertEqual(whileSuspended.count, 2)
        await channel.releaseSuspended(.receipt(.completed))
        try await wait { model.records.first?.text == "Edited safely" && model.state == .ready }
        XCTAssertEqual(model.query, "")
        let afterReceipt = await channel.commands()
        XCTAssertEqual(afterReceipt.map(\.operation), [.listRecords, .editRecord, .listRecords])
    }

    func testFirstPageTimeoutShowsFixedErrorAndCancelsLateReply() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.errorMessage, "Memories could not be loaded. Try again.")
        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .listRecords,
            status: .completed, records: [record("late-page")])))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.state, .error("Memories could not be loaded. Try again."))
    }

    func testLoadMoreTimeoutRetainsRowsAndCursor() async throws {
        let channel = MemoryDisplayChannel()
        let page = records("kept", count: 20)
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: page, nextRecordID: "kept-019")))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { model.records.count == 20 && model.state == .ready }
        await channel.suspendNext()
        model.loadMore()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.records, page)
        XCTAssertEqual(model.nextRecordID, "kept-019")
        XCTAssertEqual(model.errorMessage, "Memories could not be loaded. Try again.")
    }

    func testEditTimeoutKeepsExactRetryAndNeverAutomaticallyResends() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("fact-a", text: "Edited after retry")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { model.records.count == 1 }
        await channel.suspendNext()
        model.edit(record: visible, text: "Edited after retry")
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.errorMessage, "The change may have completed. Reload before trying again.")
        let afterTimeout = await channel.commands()
        XCTAssertEqual(afterTimeout.map(\.operation), [.listRecords, .editRecord])
        let originalID = afterTimeout.last?.commandID
        model.edit(record: visible, text: "Edited after retry")
        try await wait { model.records.first?.text == "Edited after retry" && model.state == .ready }
        let afterRetry = await channel.commands()
        let edits = afterRetry.filter { $0.operation == .editRecord }
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].commandID, originalID)
        XCTAssertEqual(edits[1].commandID, originalID)
        await channel.releaseSuspended(.receipt(.completed))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.records.first?.text, "Edited after retry")
    }

    func testLateTimedOutPageCannotReplaceNewQuery() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [record("new-query-result")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open(query: "old")
        try await wait { if case .error = model.state { return true }; return false }
        model.open(query: "new")
        try await wait { model.records.first?.recordID == "new-query-result" }
        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .searchRecords,
            status: .completed, records: [record("stale-query-result")])))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.query, "new")
        XCTAssertEqual(model.records.map(\.recordID), ["new-query-result"])
    }

    func testCloseCancelsDeadlineWithoutRevivingError() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("available")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(50))
        model.open()
        try await wait { model.state == .ready }
        model.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(model.errorMessage, "Memory is unavailable for this connection.")
    }

    func testDeinitReleasesControllerWithSuspendedChannelCall() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        var model: PersonalMemoryViewModel? = PersonalMemoryViewModel(
            enabled: true, channel: channel, requestTimeout: .milliseconds(40))
        weak var weakModel = model
        model?.open()
        try await wait { await channel.commands().count == 1 }
        model = nil
        try await wait { weakModel == nil }
        await channel.releaseSuspended(.failure)
        try await wait { await channel.sawCancellation() }
    }

    func testCompletedDeadlineCannotReopenOrExpireLaterRequest() async throws {
        let channel = MemoryDisplayChannel()
        let sleeper = ManualDeadlineSleeper()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("first-result")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
            requestTimeout: .seconds(10), deadlineSleep: { duration in try await sleeper.sleep(duration) })
        model.open()
        try await wait { model.state == .ready }
        try await wait { await sleeper.waitingCount() >= 1 }
        await sleeper.releaseNext()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.state, .ready)

        await channel.suspendNext()
        model.open(query: "new")
        try await wait { await channel.commands().count == 2 }
        try await wait { await sleeper.waitingCount() >= 1 }
        if await sleeper.waitingCount() >= 2 {
            await sleeper.releaseNext()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .loading)
        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .searchRecords,
            status: .completed, records: [record("later-result")])))
        try await wait { model.records.first?.recordID == "later-result" && model.state == .ready }
        await sleeper.releaseAll()
    }

    func testFirstPageTimeoutStillCapturesGenerationAndIgnoresLatePageReply() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { await channel.allCommands().count == 2 }
        try await wait { model.generationReference != nil && model.state == .error("Memories could not be loaded. Try again.") }
        let commands = await channel.allCommands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .captureMemoryGeneration])
        XCTAssertEqual(model.state, .error("Memories could not be loaded. Try again."))
        let capturedReference = try XCTUnwrap(model.generationReference)
        XCTAssertEqual(model.records, [])

        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .listRecords,
            status: .completed, records: [record("late-page")])))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.state, .error("Memories could not be loaded. Try again."))
        XCTAssertEqual(model.generationReference, capturedReference)
        XCTAssertEqual(model.records, [])
        let afterLateReply = await channel.allCommands()
        XCTAssertEqual(afterLateReply.map(\.operation), [.listRecords, .captureMemoryGeneration])
    }

    func testEditReceiptSurvivesSearchResultDisappearingAfterEdit() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .searchRecords, status: .completed)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open(query: "fact")
        try await wait { model.records.count == 1 }
        let requestID = try XCTUnwrap(model.edit(record: visible, text: "Updated fact"))
        try await wait {
            model.mutationReceipt?.matches(kind: .edit, recordID: visible.recordID, requestID: requestID) == true
        }
        try await wait { model.state == .ready && model.records.isEmpty }
        XCTAssertTrue(model.mutationReceipt?.matches(kind: .edit, recordID: visible.recordID,
                                                     requestID: requestID) == true)
    }

    func testEditReceiptSurvivesFollowupReloadFailure() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        let requestID = try XCTUnwrap(model.edit(record: visible, text: "Updated fact"))
        try await wait {
            model.mutationReceipt?.matches(kind: .edit, recordID: visible.recordID, requestID: requestID) == true
        }
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertTrue(model.mutationReceipt?.matches(kind: .edit, recordID: visible.recordID,
                                                     requestID: requestID) == true)
    }

    func testFailedOrMalformedMutationsDoNotEmitReceipt() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.mismatchedEditReceipt)
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .deleteMetadata, status: .unavailable)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.edit(record: visible, text: "Bad receipt")
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertNil(model.mutationReceipt)
        model.delete(record: visible)
        try await wait { model.state == .error("The change may have completed. Reload before trying again.") }
        XCTAssertNil(model.mutationReceipt)
    }

    func testDeleteReceiptRequiresCorrelatedCompletedReply() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .deleteMetadata, status: .completed)))
        await channel.enqueue(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        let requestID = try XCTUnwrap(model.delete(record: visible))
        try await wait {
            model.mutationReceipt?.matches(kind: .delete, recordID: visible.recordID, requestID: requestID) == true
        }
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertTrue(model.mutationReceipt?.matches(kind: .delete, recordID: visible.recordID,
                                                     requestID: requestID) == true)
    }

    func testCloseClearsMutationReceipt() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        let requestID = try XCTUnwrap(model.edit(record: visible, text: "Updated"))
        try await wait {
            model.mutationReceipt?.matches(kind: .edit, recordID: visible.recordID, requestID: requestID) == true
        }
        model.close()
        XCTAssertNil(model.mutationReceipt)
    }

    func testLateCompletedMutationAfterCloseOrDisconnectDoesNotPublishReceipt() async throws {
        for disconnect in [false, true] {
            let channel = MemoryDisplayChannel()
            let visible = record("fact-a")
            await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
                records: [visible])))
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.records.count == 1 }
            await channel.suspendNext()
            model.edit(record: visible, text: "Late result")
            try await wait { await channel.commands().count == 2 }
            if disconnect { model.disconnect() } else { model.close() }
            await channel.releaseSuspended(.receipt(.completed))
            try await wait { await channel.sawCancellation() }
            XCTAssertNil(model.mutationReceipt)
            XCTAssertTrue(model.records.isEmpty)
        }
    }

    func testMutationReceiptCannotMatchPriorEditorRequest() {
        let receipt = PersonalMemoryViewModel.MutationReceipt(kind: .edit, recordID: "fact-a", requestID: "old")
        XCTAssertTrue(receipt.matches(kind: .edit, recordID: "fact-a", requestID: "old"))
        XCTAssertFalse(receipt.matches(kind: .edit, recordID: "fact-a", requestID: "new"))
        XCTAssertFalse(receipt.matches(kind: .delete, recordID: "fact-a", requestID: "old"))
        XCTAssertFalse(receipt.matches(kind: .edit, recordID: "fact-b", requestID: "old"))
    }

    func testUnknownDraftRecoversAfterEditorDismissalWithoutSending() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.failure)
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("fact-a", text: "Retry this exact draft")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        let firstRequest = try XCTUnwrap(model.edit(record: visible, text: "Retry this exact draft"))
        try await wait { if case .error = model.state { return true }; return false }
        let commandCountBeforeReopen = await channel.commands().count
        XCTAssertEqual(model.recoverableDraft(for: visible), "Retry this exact draft")
        XCTAssertNil(model.recoverableDraft(for: record("fact-a", revision: String(repeating: "b", count: 64))))
        XCTAssertNil(model.recoverableDraft(for: record("different-fact")))
        XCTAssertEqual(commandCountBeforeReopen, 2)
        guard let restoredDraft = model.recoverableDraft(for: visible) else { return }
        let reopenedRequest = try XCTUnwrap(model.edit(record: visible, text: restoredDraft))
        XCTAssertEqual(reopenedRequest, firstRequest)
        try await wait { model.records.first?.text == "Retry this exact draft" }
        let editCommands = await channel.commands().filter { $0.operation == .editRecord }
        XCTAssertEqual(editCommands.map(\.commandID), [firstRequest, firstRequest])
    }

    func testRepeatedCursorAndDuplicateIDsFailClosed() async throws {
        let channel = MemoryDisplayChannel()
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: records("fact", count: 20), nextRecordID: "fact-019")))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: records("fact", count: 20), nextRecordID: "fact-019")))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.nextRecordID == "fact-019" }
        model.loadMore()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.records.count, 20)
    }

    func testInvalidRecordAndShortContinuingPageFailClosed() async throws {
        let channel = MemoryDisplayChannel()
        let invalid = LocalMemoryRPCRecord(recordID: "", kind: .fact, text: "Private fact",
            observedAtMilliseconds: 1_800_000_000_000, active: true,
            revision: String(repeating: "0", count: 64), source: .ownerMessage)
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [invalid])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        let firstCalls = await channel.commands()
        XCTAssertEqual(firstCalls.count, 1)
        XCTAssertTrue(model.records.isEmpty)

        let secondChannel = MemoryDisplayChannel()
        await secondChannel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("short-001")], nextRecordID: "short-001")))
        let secondModel = PersonalMemoryViewModel(enabled: true, channel: secondChannel)
        secondModel.open()
        try await wait { if case .error = secondModel.state { return true }; return false }
        XCTAssertTrue(secondModel.records.isEmpty)
        XCTAssertNil(secondModel.nextRecordID)
    }

    func testLoadMoreFailureKeepsRowsAndCursorWithoutClaimingComplete() async throws {
        let channel = MemoryDisplayChannel()
        let page = records("keep", count: 20)
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: page, nextRecordID: "keep-019")))
        await channel.enqueue(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 20 && model.state == .ready }
        model.loadMore()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.records, page)
        XCTAssertEqual(model.nextRecordID, "keep-019")
    }

    func testDisconnectRequiresNewBindingAndDropsCancelledCompletion() async throws {
        let channel = MemoryDisplayChannel()
        await channel.suspendNext()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { await channel.commands().count == 1 }
        model.disconnect()
        await channel.releaseSuspended(.reply(LocalMemoryRPCReply(operation: .listRecords,
            status: .completed, records: [record("must-not-return")])))
        try await wait { await channel.sawCancellation() }
        model.open()
        let commands = await channel.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.state, .unavailable)
    }

    func testStaleSheetRevisionIsRejectedLocally() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a", revision: String(repeating: "a", count: 64))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.edit(record: record("fact-a", revision: String(repeating: "b", count: 64)), text: "stale")
        model.delete(record: record("fact-a", revision: String(repeating: "b", count: 64)))
        let commands = await channel.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(model.records, [visible])
        XCTAssertEqual(model.errorMessage, "This memory changed elsewhere. Reload before editing it.")
    }

    func testDeleteFailureDoesNotAutomaticallyRetry() async throws {
        let channel = MemoryDisplayChannel()
        let visible = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [visible])))
        await channel.enqueue(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.delete(record: visible)
        try await wait { if case .error = model.state { return true }; return false }
        try await Task.sleep(for: .milliseconds(20))
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .deleteMetadata])
        XCTAssertEqual(model.errorMessage, "The change may have completed. Reload before trying again.")
    }

    func testEditUsesDisplayedRevisionAndExplicitRetryReusesExactCommand() async throws {
        let channel = MemoryDisplayChannel()
        let displayed = record("fact-a", revision: String(repeating: "a", count: 64))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [displayed])))
        await channel.enqueue(.failure)
        await channel.enqueue(.receipt(.completed))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [record("fact-a", text: "Edited fact")])))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.first?.recordID == "fact-a" }
        model.edit(record: displayed, text: "Edited fact")
        try await wait { if case .error = model.state { return true }; return false }
        let firstAttempt = await channel.commands().last
        model.edit(record: displayed, text: "Edited fact")
        try await wait { model.records.first?.text == "Edited fact" }
        let edits = await channel.commands().filter { $0.operation == .editRecord }
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].commandID, edits[1].commandID)
        XCTAssertEqual(edits[0].commandID, firstAttempt?.commandID)
        XCTAssertEqual(edits.map(\.revision), [displayed.revision, displayed.revision])
        XCTAssertEqual(edits.map(\.text), ["Edited fact", "Edited fact"])
    }

    func testStaleEditConflictDoesNotOverwriteAndShowsSafeMessage() async throws {
        let channel = MemoryDisplayChannel()
        let displayed = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [displayed])))
        await channel.enqueue(.receipt(.conflict))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.edit(record: displayed, text: "New text")
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertEqual(model.records, [displayed])
        XCTAssertEqual(model.errorMessage, "This memory changed elsewhere. Reload before editing it.")
    }

    func testDeleteRequiresVisibleRecordThenReloadsAndNeverAutoRetries() async throws {
        let channel = MemoryDisplayChannel()
        let displayed = record("fact-a")
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed,
            records: [displayed])))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .deleteMetadata, status: .completed)))
        await channel.enqueue(.reply(LocalMemoryRPCReply(operation: .listRecords, status: .completed)))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.delete(record: record("foreign-record"))
        try await Task.sleep(for: .milliseconds(20))
        let unchangedCalls = await channel.commands()
        XCTAssertEqual(unchangedCalls.count, 1)
        model.delete(record: displayed)
        try await wait { model.records.isEmpty && model.state == .ready }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .deleteMetadata, .listRecords])
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MemoryDisplayChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func record(_ id: String, text: String = "A private owner fact",
                        revision: String = String(repeating: "0", count: 64)) -> LocalMemoryRPCRecord {
        LocalMemoryRPCRecord(recordID: id, kind: .fact, text: text, observedAtMilliseconds: 1_800_000_000_000,
            active: true, revision: revision, source: .ownerMessage)
    }

    private func records(_ prefix: String, count: Int) -> [LocalMemoryRPCRecord] {
        (0..<count).map { record(String(format: "%@-%03d", prefix, $0)) }
    }
}

private actor MemoryDisplayChannel: PersonalMemoryChannel {
    enum Failure: Error { case requested, timeout }
    enum Action: Sendable {
        case reply(LocalMemoryRPCReply)
        case receipt(LocalMemoryRPCReply.Status)
        case mismatchedEditReceipt
        case failure
    }
    private var actions: [Action] = []
    private var received: [LocalMemoryRPCCommand] = []
    private var suspendOne = false
    private var continuation: CheckedContinuation<Action, Never>?
    private var cancellationObserved = false

    func enqueue(_ action: Action) { actions.append(action) }
    func suspendNext() { suspendOne = true }
    func releaseSuspended(_ action: Action) { continuation?.resume(returning: action); continuation = nil }
    func commands() -> [LocalMemoryRPCCommand] {
        received.filter { $0.operation != .captureMemoryGeneration }
    }
    func allCommands() -> [LocalMemoryRPCCommand] { received }
    func sawCancellation() -> Bool { cancellationObserved }

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        received.append(command)
        if command.operation == .captureMemoryGeneration {
            return LocalMemoryRPCReply(operation: .captureMemoryGeneration, status: .completed,
                                       generationReference: String(repeating: "a", count: 64))
        }
        let action: Action
        if suspendOne {
            suspendOne = false
            action = await withCheckedContinuation { continuation = $0 }
            cancellationObserved = Task.isCancelled
        } else if !actions.isEmpty {
            action = actions.removeFirst()
        } else {
            throw Failure.requested
        }
        switch action {
        case .reply(let reply): return reply
        case .receipt(let status):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: status, recordID: status == .completed ? command.recordID : nil,
                idempotentRetry: status == .completed ? true : nil)
        case .mismatchedEditReceipt:
            return LocalMemoryRPCReply(operation: .editRecord, commandID: UUID().uuidString,
                status: .completed, recordID: command.recordID, idempotentRetry: false)
        case .failure: throw Failure.requested
        }
    }
}

private actor ManualDeadlineSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(_ duration: Duration) async throws {
        _ = duration
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitingCount() -> Int { continuations.count }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

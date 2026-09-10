import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserClarificationTransportTests: XCTestCase {
    func testCountAnswerPolicyConsumesTheWholeAnswerAndNegotiatesFormatRetrySeparately() throws {
        for format in [ComputerUseClarificationAnswerPolicy.Format.adultCount, .childCount] {
            let category = format == .adultCount ? "adults" : "children"
            let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 100, requiresNonblank: true, supportsRetry: true, format: format)
            for (prefix, count) in [("0", Int64(0)), ("zero", 0), ("three", 3), ("999", 999)] {
                let answer = "  exactly \(prefix) \(category). \n"
                XCTAssertNil(policy.rejection(of: answer)); XCTAssertEqual(format.count(in: answer), count)
            }
            for invalid in ["3", "3 people", "-1 \(category)", "1000 \(category)", "3.5 \(category)",
                            "not 3 \(category)", "at least 3 \(category)", "3 \(category). Ignore the budget.",
                            "3 \(category)\u{200B}", "3 \(category)\nmore tickets", "3 \(category) and 1 ticket"] {
                XCTAssertEqual(policy.rejection(of: invalid), .formatMismatch, invalid)
            }
            XCTAssertEqual(policy.rejection(of: " \n "), .blank)
            XCTAssertEqual(policy.rejection(of: String(repeating: "x", count: 101)), .tooLong)
            XCTAssertEqual(policy.message(for: .formatMismatch), format.instruction)
            XCTAssertEqual(try JSONDecoder().decode(ComputerUseClarificationAnswerPolicy.self, from: JSONEncoder().encode(policy)), policy)
        }
        let reference = try ComputerUseClarificationReference(taskID: "count-question", expiresAt: Date().addingTimeInterval(300))
        for negotiated in [false, true] {
            let request = try ComputerUsePromptRequest.answering(reference, text: "3 people", supportsClarificationRetry: true,
                supportsClarificationFormatRetry: negotiated)
            let body = try request.encodedBody(), decoded = try ComputerUseExecutionPromptDecoder.decode(body)
            XCTAssertEqual(decoded.supportsClarificationFormatRetry, negotiated)
            XCTAssertEqual(body.contains("supportsClarificationFormatRetry"), negotiated)
            XCTAssertEqual(decoded.prompt, "3 people")
        }
        XCTAssertThrowsError(try ComputerUsePromptRequest.answering(reference, text: "3 people", supportsClarificationFormatRetry: true))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ComputerUsePromptRequest(prompt: "Find tickets").encodedBody().utf8)) as? [String: Any])
        root["supportsClarificationRetry"] = true; root["supportsClarificationFormatRetry"] = true
        XCTAssertThrowsError(try ComputerUseExecutionPromptDecoder.decode(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self)))
        let legacy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 100, requiresNonblank: true, supportsRetry: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("format"))
        XCTAssertThrowsError(try ComputerUseClarificationRetry(reference: reference, reason: .formatMismatch, answerPolicy: legacy))
    }

    func testComponentAnswerRejectionRetainsNativeQuestionAndRequiresExactLiveFormatForReplay() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        planner.requirementRows = [
            ["source":"Find concerts. ", "turn":0, "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["source":"2 adults and 1 child.", "turn":0, "role":"condition", "field":"quantity", "relation":"unspecified", "values":[]]]
        let owner = try makeOwner(browser, planner: planner, prompt: "Find concerts. 2 adults and 1 child.", now: { now })
        let original = owner.input, proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        let root = request(original.taskID)
        let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .replaceChildren,
            requirementIDs: [proposal.requirements[1].id]), owner: owner, for: root)
        let nativeQuestion = try XCTUnwrap(owner.pendingQuestion(controllerID: root.senderID, controllerSessionID: root.sessionID))
        let policy = try XCTUnwrap(bridge.answerPolicy(for: issued.reference, envelope: root))
        XCTAssertEqual(policy.format, .childCount)
        now = now.addingTimeInterval(20)
        let body = try ComputerUsePromptRequest.answering(issued.reference, text: "3 people", supportsClarificationRetry: true,
            supportsClarificationFormatRetry: true).encodedBody(), attempt = request("invalid-count", body: body)
        let rejection: ComputerUseBrowserClarificationTransport.RejectedAnswer
        do {
            _ = try bridge.consume(issued.reference, answer: "3 people", for: attempt, retainedOwner: { _ in owner })
            return XCTFail("A mismatched category must leave the native question open")
        } catch let error as ComputerUseBrowserClarificationTransport.RejectedAnswer { rejection = error }
        XCTAssertEqual(rejection.retry.reason, .formatMismatch); XCTAssertEqual(rejection.retry.answerPolicy, policy)
        XCTAssertEqual(rejection.text, issued.text); XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.executionTaskID, root.id)
        XCTAssertEqual(try owner.pendingQuestion(controllerID: root.senderID, controllerSessionID: root.sessionID), nativeQuestion)
        XCTAssertTrue(bridge.retainsRetry(rejection.retry, for: attempt, retainedOwner: { _ in owner }))
        let legacyAttempt = request("legacy-count", body: try ComputerUsePromptRequest.answering(issued.reference, text: "3 people",
            supportsClarificationRetry: true).encodedBody())
        XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: legacyAttempt, retainedOwner: { _ in owner }))
        let forged = try ComputerUseClarificationRetry(reference: issued.reference, reason: .formatMismatch,
            answerPolicy: .init(maximumUTF8Bytes: policy.maximumUTF8Bytes, requiresNonblank: true, supportsRetry: true, format: .adultCount))
        XCTAssertFalse(bridge.retainsRetry(forged, for: attempt, retainedOwner: { _ in owner }))
        let corrected = request("corrected-count", body: try ComputerUsePromptRequest.answering(issued.reference, text: "zero children",
            supportsClarificationRetry: true, supportsClarificationFormatRetry: true).encodedBody())
        _ = try bridge.consume(issued.reference, answer: "zero children", for: corrected, retainedOwner: { _ in owner })
        XCTAssertEqual(owner.input.userTurns, [original.prompt, "zero children"])
        XCTAssertEqual(owner.input.rootDateContext, original.rootDateContext)
        XCTAssertEqual(planner.inputs.count, 1)
        XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: attempt, retainedOwner: { _ in owner }))
    }

    func testQuestionRecoveryProbeWireIsDistinctBoundedAndOnlyAdvertisedForScopedQuestions() throws {
        let reference = try ComputerUseClarificationReference(taskID: "question", expiresAt: Date().addingTimeInterval(300))
        let probe = ComputerUseClarificationProbe(reference: reference)
        XCTAssertEqual(try ComputerUseClarificationProbe.decodeBody(probe.encodedBody()), probe)
        XCTAssertThrowsError(try ComputerUseTaskUpdate.decodeBody(probe.encodedBody()))
        XCTAssertThrowsError(try ComputerUseClarificationProbe.decodeBody(ComputerUseTaskUpdate(taskID: "question", text: "ready").encodedBody()))
        XCTAssertThrowsError(try ComputerUseClarificationProbe.decodeBody(String(repeating: " ", count: 2_049)))
        let full = String(repeating: "é", count: 64 * 1_024)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 8_192, requiresNonblank: true, supportsRetry: true)
        let result = try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: full, answerPolicy: policy)
        XCTAssertEqual(try ComputerUseClarificationProbeResult.decodeBody(result.encodedBody()), result)
        XCTAssertThrowsError(try ComputerUseTaskUpdate.decodeBody(result.encodedBody()))
        XCTAssertThrowsError(try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: " "))
        XCTAssertThrowsError(try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: full + "é"))
        XCTAssertThrowsError(try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: nil, answerPolicy: policy))
        let unavailable = try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: nil)
        XCTAssertNil(try ComputerUseClarificationProbeResult.decodeBody(unavailable.encodedBody()).question)
        let question = ComputerUseTaskUpdate(taskID: reference.taskID, text: "Which city?", outcome: .userInterventionRequired,
            clarification: reference, supportsClarificationRecovery: true)
        XCTAssertTrue(try ComputerUseTaskUpdate.decodeBody(question.encodedBody()).supportsClarificationRecovery)
        XCTAssertThrowsError(try ComputerUseTaskUpdate(taskID: reference.taskID, text: "ready", supportsClarificationRecovery: true).encodedBody())
        let legacy = try ComputerUseTaskUpdate(taskID: reference.taskID, text: "Which city?", outcome: .userInterventionRequired,
            clarification: reference).encodedBody()
        XCTAssertFalse(legacy.contains("supportsClarificationRecovery"))
        XCTAssertFalse(try ComputerUseTaskUpdate.decodeBody(legacy).supportsClarificationRecovery)
    }

    func testQuestionDeliveryRequiresRegisteredOwnerAndUnchangedLiveScope() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        let owner = try makeOwner(browser, planner: planner, now: { now }), original = owner.input
        let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        let envelope = request(original.taskID)
        let question = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .location,
            requirementIDs: [proposal.requirements[0].id]), owner: owner, for: envelope)
        XCTAssertTrue(bridge.retainsRegisteredQuestion(question.reference, for: envelope, retainedOwner: { _ in owner }))
        XCTAssertFalse(bridge.retainsRegisteredQuestion(question.reference, for: envelope, retainedOwner: { _ in nil }))
        let replacement = try makeOwner(browser, planner: planner)
        XCTAssertFalse(bridge.retainsRegisteredQuestion(question.reference, for: envelope, retainedOwner: { _ in replacement }))
        XCTAssertFalse(bridge.retainsRegisteredQuestion(question.reference, for: request(original.taskID, sender: "other"), retainedOwner: { _ in owner }))
        XCTAssertFalse(bridge.retainsRegisteredQuestion(question.reference, for: request(original.taskID, session: "other"), retainedOwner: { _ in owner }))
        now = question.reference.expiresAt
        XCTAssertFalse(bridge.retainsRegisteredQuestion(question.reference, for: envelope, retainedOwner: { _ in owner }))
        XCTAssertEqual(owner.input, original)
    }

    func testLedgerRetainsBrowserQuestionKindWithoutInventingLegacyOwnersOrRestoringCancelledReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json"), ledger = ComputerUseTaskLedger(fileURL: url)
        let reference = try ComputerUseClarificationReference(taskID: "browser", expiresAt: Date().addingTimeInterval(600))
        _ = try ledger.claim(taskID: "browser", senderID: "phone", sessionID: "session", promptBody: "Find tickets.")
        XCTAssertThrowsError(try ledger.complete(taskID: "browser", response: "Done", outcome: .taskCompleted, clarificationOwner: .browser))
        _ = try ledger.complete(taskID: "browser", response: "Which location?", outcome: .userInterventionRequired,
            clarification: reference, clarificationOwner: .browser)
        let restored = ComputerUseTaskLedger(fileURL: url)
        XCTAssertEqual(restored.clarificationOwner(taskID: "browser"), .browser); XCTAssertEqual(restored.terminalClarification(taskID: "browser"), reference)
        _ = try restored.complete(taskID: "browser", response: "Late result", outcome: .unableToComplete)
        XCTAssertEqual(ComputerUseTaskLedger(fileURL: url).clarificationOwner(taskID: "browser"), .browser)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for mutation in ["legacy", "unknown-kind", "wrong-task", "no-reference", "wrong-outcome"] {
            var changed = records, row = try XCTUnwrap(records["browser"] as? [String: Any])
            switch mutation {
            case "legacy": row.removeValue(forKey: "clarificationOwner")
            case "unknown-kind": row["clarificationOwner"] = "unrecognized"
            case "wrong-task":
                var ref = try XCTUnwrap(row["clarification"] as? [String: Any]); ref["taskID"] = "other"; row["clarification"] = ref
            case "no-reference": row.removeValue(forKey: "clarification")
            default: row["outcome"] = ComputerUseTerminalOutcome.taskCompleted.rawValue
            }
            changed["browser"] = row
            let changedURL = directory.appendingPathComponent(mutation + ".json")
            try JSONSerialization.data(withJSONObject: changed).write(to: changedURL)
            let reopened = ComputerUseTaskLedger(fileURL: changedURL)
            if mutation == "legacy" {
                XCTAssertNil(reopened.clarificationOwner(taskID: "browser"))
                XCTAssertEqual(reopened.terminalClarification(taskID: "browser"), reference)
                XCTAssertEqual(try reopened.claim(taskID: "browser", senderID: "phone", sessionID: "session", promptBody: "Find tickets."), .completed("Which location?"))
            } else {
                XCTAssertThrowsError(try reopened.claim(taskID: "new", senderID: "phone", sessionID: "session", promptBody: "New request"))
            }
        }
        _ = try restored.cancelLocally(taskID: "browser", senderID: "phone", sessionID: "session")
        let cancelled = ComputerUseTaskLedger(fileURL: url)
        XCTAssertEqual(cancelled.clarificationOwner(taskID: "browser"), .browser); XCTAssertTrue(cancelled.isCancelled(taskID: "browser"))
        XCTAssertNil(cancelled.terminalClarification(taskID: "browser"))
    }

    func testRetryWireNegotiatesOnlyExplicitAnswerSupportAndKeepsTheCompleteQuestion() throws {
        let reference = try ComputerUseClarificationReference(taskID: "root", expiresAt: Date().addingTimeInterval(600))
        for negotiated in [false, true] {
            let body = try ComputerUsePromptRequest.answering(reference, text: "  ", supportsClarificationRetry: negotiated).encodedBody()
            let decoded = try ComputerUseExecutionPromptDecoder.decode(body)
            XCTAssertEqual(decoded.supportsClarificationRetry, negotiated)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            XCTAssertEqual(fields["supportsClarificationRetry"] != nil, negotiated)
        }
        let oldPolicy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 8, requiresNonblank: true)
        let oldData = try JSONEncoder().encode(oldPolicy)
        XCTAssertFalse(try JSONDecoder().decode(ComputerUseClarificationAnswerPolicy.self, from: oldData).supportsRetry)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("supportsRetry"))
        XCTAssertThrowsError(try ComputerUseClarificationRetry(reference: reference, reason: .blank, answerPolicy: oldPolicy))
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 8, requiresNonblank: true, supportsRetry: true)
        let retry = try ComputerUseClarificationRetry(reference: reference, reason: .tooLong, answerPolicy: policy)
        let question = String(repeating: "é", count: ComputerUseClarificationText.maximumUTF8Bytes / 2)
        let update = ComputerUseTaskUpdate(taskID: "attempt", text: question, outcome: .userInterventionRequired, clarificationRetry: retry)
        let body = try update.encodedBody(), decoded = try ComputerUseTaskUpdate.decodeBody(body)
        XCTAssertTrue(decoded.text.utf8.elementsEqual(question.utf8)); XCTAssertEqual(decoded.clarificationRetry, retry)
        let ownQuestion = try ComputerUseClarificationReference(taskID: "attempt", expiresAt: reference.expiresAt)
        for invalid in [
            ComputerUseTaskUpdate(taskID: "root", text: "Question", outcome: .userInterventionRequired, clarificationRetry: retry),
            .init(taskID: "attempt", text: "Question", outcome: .unableToComplete, clarificationRetry: retry),
            .init(taskID: "attempt", text: "Question", outcome: .userInterventionRequired, clarification: ownQuestion, clarificationRetry: retry),
            .init(taskID: "attempt", text: "Question", outcome: .userInterventionRequired, clarificationAnswerPolicy: policy, clarificationRetry: retry),
            .init(taskID: "attempt", text: "Question", outcome: .userInterventionRequired, clarificationRetry: retry, isApprovedActionEvidenceOnly: true),
            .init(taskID: "attempt", text: question + "é", outcome: .userInterventionRequired, clarificationRetry: retry),
        ] { XCTAssertThrowsError(try invalid.encodedBody()) }
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        var retryFields = try XCTUnwrap(fields["clarificationRetry"] as? [String: Any])
        retryFields["reason"] = "tryAgain"; fields["clarificationRetry"] = retryFields
        XCTAssertThrowsError(try ComputerUseTaskUpdate.decodeBody(String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self)))
    }

    func testRejectedAnswerRetryRequiresTheSameInvalidBodyOwnerControllerAndLiveQuestion() async throws {
        for retirement in ["expiry", "pause", "retire", "invalidate"] {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
            defer { browser.close() }
            let owner = try makeOwner(browser, planner: planner, now: { now }), original = owner.input
            let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
            let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .location,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request(original.taskID))
            let body = try ComputerUsePromptRequest.answering(issued.reference, text: " \n ", supportsClarificationRetry: true).encodedBody()
            let envelope = request("attempt", body: body)
            let rejection: ComputerUseBrowserClarificationTransport.RejectedAnswer
            do {
                _ = try bridge.consume(issued.reference, answer: " \n ", for: envelope, retainedOwner: { _ in owner })
                return XCTFail("A blank answer must be rejected before appending")
            } catch let error as ComputerUseBrowserClarificationTransport.RejectedAnswer { rejection = error }
            XCTAssertEqual(rejection.text, issued.text); XCTAssertEqual(rejection.retry.reference, issued.reference)
            XCTAssertEqual(rejection.retry.reason, .blank); XCTAssertEqual(owner.input, original)
            XCTAssertEqual(owner.executionTaskID, original.taskID)
            XCTAssertTrue(bridge.retainsRetry(rejection.retry, for: envelope, retainedOwner: { _ in owner }))
            XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: envelope, retainedOwner: { _ in nil }))
            let replacement = try makeOwner(browser, planner: planner)
            XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: envelope, retainedOwner: { _ in replacement }))
            for foreign in [request("attempt", sender: "other", body: body), request("attempt", session: "other", body: body),
                            request(original.taskID, body: body), request("attempt", body: "") ] {
                XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: foreign, retainedOwner: { _ in owner }))
            }
            for (text, negotiated) in [("Paris", true), (" \n ", false)] {
                let changed = request("attempt", body: try ComputerUsePromptRequest.answering(issued.reference, text: text,
                    supportsClarificationRetry: negotiated).encodedBody())
                XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: changed, retainedOwner: { _ in owner }))
            }
            switch retirement {
            case "expiry": now = issued.reference.expiresAt
            case "pause": owner.pause()
            case "retire": owner.retire()
            default: bridge.invalidate()
            }
            XCTAssertFalse(bridge.retainsRetry(rejection.retry, for: envelope, retainedOwner: { _ in owner }), retirement)
            XCTAssertEqual(owner.input, original)
        }
    }

    func testRetryLedgerRequiresAnAuthenticatedQuestionAndRetainsCancellationAssociation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json"), ledger = ComputerUseTaskLedger(fileURL: url)
        let reference = try ComputerUseClarificationReference(taskID: "root", expiresAt: Date().addingTimeInterval(600))
        let retry = try ComputerUseClarificationRetry(reference: reference, reason: .blank,
            answerPolicy: .init(maximumUTF8Bytes: 8_192, requiresNonblank: true, supportsRetry: true))
        _ = try ledger.claim(taskID: "root", senderID: "phone", sessionID: "session", promptBody: "Find tickets.")
        _ = try ledger.complete(taskID: "root", response: "Which location?", outcome: .userInterventionRequired, clarification: reference)
        for (id, sender, session) in [("foreign-sender", "other", "session"), ("foreign-session", "phone", "other")] {
            _ = try ledger.claim(taskID: id, senderID: sender, sessionID: session, promptBody: "invalid")
            XCTAssertThrowsError(try ledger.complete(taskID: id, response: "Which location?", outcome: .userInterventionRequired, clarificationRetry: retry))
            XCTAssertNil(ledger.terminalClarificationRetry(taskID: id))
        }
        let body = try ComputerUsePromptRequest.answering(reference, text: " \n ", supportsClarificationRetry: true).encodedBody()
        _ = try ledger.claim(taskID: "attempt", senderID: "phone", sessionID: "session", promptBody: body)
        let result = try ledger.complete(taskID: "attempt", response: "Which location?", outcome: .userInterventionRequired, clarificationRetry: retry)
        XCTAssertEqual(result.clarificationRetry, retry)
        let reopened = ComputerUseTaskLedger(fileURL: url)
        XCTAssertEqual(reopened.terminalClarificationRetry(taskID: "attempt"), retry)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for corruption in ["outcome", "response", "self-reference"] {
            var records = stored, row = try XCTUnwrap(stored["attempt"] as? [String: Any])
            if corruption == "outcome" { row["outcome"] = ComputerUseTerminalOutcome.taskCompleted.rawValue }
            else if corruption == "response" { row["response"] = " " }
            else {
                var metadata = try XCTUnwrap(row["clarificationRetry"] as? [String: Any])
                var corruptedReference = try XCTUnwrap(metadata["reference"] as? [String: Any])
                corruptedReference["taskID"] = "attempt"; metadata["reference"] = corruptedReference
                row["clarificationRetry"] = metadata
            }
            records["attempt"] = row
            let corruptedURL = directory.appendingPathComponent("corrupt-" + corruption + ".json")
            try JSONSerialization.data(withJSONObject: records).write(to: corruptedURL)
            XCTAssertThrowsError(try ComputerUseTaskLedger(fileURL: corruptedURL).claim(taskID: "another",
                senderID: "phone", sessionID: "session", promptBody: "New request"))
        }
        XCTAssertEqual(try reopened.claim(taskID: "attempt", senderID: "phone", sessionID: "session", promptBody: body), .completed("Which location?"))
        XCTAssertEqual(try reopened.claim(taskID: "attempt", senderID: "phone", sessionID: "session", promptBody: body + " "), .identityMismatch)
        XCTAssertEqual(try reopened.complete(taskID: "attempt", response: "Late completion", outcome: .taskCompleted).clarificationRetry, retry)
        _ = try reopened.cancelLocally(taskID: "attempt", senderID: "phone", sessionID: "session")
        XCTAssertNil(reopened.terminalClarificationRetry(taskID: "attempt"))
        XCTAssertEqual(ComputerUseTaskLedger(fileURL: url).rejectedAnswerReference(taskID: "attempt"), reference)
        _ = try reopened.cancelLocally(taskID: "root", senderID: "phone", sessionID: "session")
        _ = try reopened.claim(taskID: "late-attempt", senderID: "phone", sessionID: "session", promptBody: body)
        XCTAssertThrowsError(try reopened.complete(taskID: "late-attempt", response: "Question", outcome: .userInterventionRequired, clarificationRetry: retry))
        XCTAssertNil(reopened.terminalClarification(taskID: "root"))
        let missing = try ComputerUseClarificationRetry(reference: .init(taskID: "missing", expiresAt: reference.expiresAt),
            reason: .blank, answerPolicy: retry.answerPolicy)
        XCTAssertThrowsError(try reopened.complete(taskID: "late-attempt", response: "Question",
            outcome: .userInterventionRequired, clarificationRetry: missing))
    }

    func testAnswerPolicyUsesRemainingNativeBytesAndOnlyTheLiveQuestion() async throws {
        let beginning = "Find concert tickets. "
        for remaining in [ComputerUseBrowserGoalInput.maximumAnswerBytes, 7] {
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
            defer { browser.close() }
            planner.useSourceReferences = true
            let prompt = remaining == 7 ? beginning + String(repeating: "x", count: ComputerUseBrowserGoalInput.maximumUserBytes - remaining - beginning.utf8.count) : beginning
            let owner = try makeOwner(browser, planner: planner, prompt: prompt), original = owner.input
            let bridge = ComputerUseBrowserClarificationTransport(), envelope = request(original.taskID)
            let proposal = try await owner.interpretGoal().proposal
            let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .location,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: envelope)
            let policy = try XCTUnwrap(bridge.answerPolicy(for: issued.reference, envelope: envelope))
            XCTAssertEqual(policy.maximumUTF8Bytes, remaining); XCTAssertTrue(policy.requiresNonblank)
            XCTAssertEqual(policy.rejection(of: " \n "), .blank)
            let foreign = try ComputerUseClarificationReference(taskID: issued.reference.taskID, expiresAt: issued.reference.expiresAt)
            XCTAssertNil(bridge.answerPolicy(for: foreign, envelope: envelope))
            XCTAssertNil(bridge.answerPolicy(for: issued.reference, envelope: request(envelope.id, sender: "foreign")))
            if remaining == 7 {
                XCTAssertEqual(policy.rejection(of: "😀éaa"), .tooLong)
                XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "😀éaa", for: request("oversized-answer"), retainedOwner: { _ in owner }))
                XCTAssertEqual(owner.input, original)
                XCTAssertEqual(bridge.answerPolicy(for: issued.reference, envelope: envelope), policy)
            }
            XCTAssertNil(policy.rejection(of: "😀éa"))
            _ = try bridge.consume(issued.reference, answer: "😀éa", for: request("accepted-answer"), retainedOwner: { _ in owner })
            XCTAssertEqual(owner.input.userTurns, [prompt, "😀éa"])
            XCTAssertEqual(owner.input.rootDateContext, original.rootDateContext)
            XCTAssertNil(bridge.answerPolicy(for: issued.reference, envelope: envelope))
        }
    }

    func testAnswerPolicyWireIsBoundedScopedAndLeavesTheOpaqueReferenceUnchanged() throws {
        let reference = try ComputerUseClarificationReference(taskID: "root", expiresAt: Date().addingTimeInterval(600))
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 7, requiresNonblank: true)
        let update = ComputerUseTaskUpdate(taskID: "root", text: "Which location?", outcome: .userInterventionRequired,
            clarification: reference, clarificationAnswerPolicy: policy)
        let body = try update.encodedBody(), decoded = try ComputerUseTaskUpdate.decodeBody(body)
        XCTAssertEqual(decoded.clarificationAnswerPolicy, policy); XCTAssertEqual(decoded.clarification, reference)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(root["clarification"] as? [String: Any]).keys), ["taskID", "nonce", "expiresAt"])
        let answer = try ComputerUseExecutionPromptDecoder.decode(ComputerUsePromptRequest.answering(reference, text: "Paris").encodedBody())
        XCTAssertEqual(answer.clarification, reference); XCTAssertEqual(answer.prompt, "Paris")
        for limit in ([0, -1, 32 * 1_024 + 1, 7.5, "7", true] as [Any]) {
            root["clarificationAnswerPolicy"] = ["maximumUTF8Bytes":limit, "requiresNonblank":true]
            XCTAssertThrowsError(try ComputerUseTaskUpdate.decodeBody(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self)))
        }
        XCTAssertThrowsError(try ComputerUseTaskUpdate(taskID: "root", text: "Unscoped", clarificationAnswerPolicy: policy).encodedBody())
        let legacy = ComputerUseTaskUpdate(taskID: "root", text: "Which field?", outcome: .userInterventionRequired, clarification: reference)
        XCTAssertNil(try ComputerUseTaskUpdate.decodeBody(legacy.encodedBody()).clarificationAnswerPolicy)
    }

    func testBrowserReferenceUsesExistingWireAndRetainsRootClockAndExactAnswers() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        let owner = try makeOwner(browser, planner: planner), root = owner.input
        let bridge = ComputerUseBrowserClarificationTransport()
        var envelope = request(root.taskID)
        for answer in ["  Paris e\u{301} 😀\n  ", "2026-10-15"] {
            let proposal = try await owner.interpretGoal().proposal
            let issued = try bridge.issue(.init(taskID: root.taskID, inputDigest: owner.input.digest, topic: .location,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: envelope)
            let displayed = try XCTUnwrap(owner.pendingQuestion(controllerID: envelope.senderID, controllerSessionID: envelope.sessionID))
            XCTAssertEqual(issued.text, displayed.text)
            XCTAssertTrue(issued.text.hasPrefix(ComputerUseBrowserClarificationTopic.location.question))
            XCTAssertTrue(issued.text.contains("⟦\(root.prompt)⟧"))
            XCTAssertEqual(issued.reference.taskID, envelope.id)
            XCTAssertTrue(bridge.retains(issued.reference, for: envelope))
            let wire = try ComputerUsePromptRequest.answering(issued.reference, text: answer, supportsApprovedActionEvidence: true).encodedBody()
            let decoded = try ComputerUseExecutionPromptDecoder.decode(wire)
            let answerEnvelope = request(UUID().uuidString)
            let continuation = try bridge.consume(XCTUnwrap(decoded.clarification), answer: decoded.prompt, for: answerEnvelope,
                retainedOwner: { $0 == root.taskID ? owner : nil })
            XCTAssertTrue(continuation.owner === owner)
            XCTAssertEqual(continuation.answerTaskID, answerEnvelope.id)
            XCTAssertEqual(continuation.inputDigest, owner.input.digest)
            XCTAssertEqual(owner.taskID, root.taskID)
            XCTAssertEqual(owner.executionTaskID, answerEnvelope.id)
            XCTAssertEqual(owner.input.referenceMilliseconds, root.referenceMilliseconds)
            XCTAssertEqual(owner.input.timeZoneIdentifier, root.timeZoneIdentifier)
            XCTAssertTrue(try XCTUnwrap(owner.input.userTurns.last).utf8.elementsEqual(answer.utf8))
            XCTAssertFalse(bridge.retains(issued.reference, for: envelope))
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: answer, for: request(UUID().uuidString), retainedOwner: { _ in owner }))
            envelope = answerEnvelope
        }
        XCTAssertEqual(owner.input.rootDigest, root.rootDigest)
        XCTAssertEqual(owner.input.userTurns.count, 3)
        XCTAssertNil(browser.taskID, "A task question is not a browser navigation")
    }

    func testBrowserReferenceRejectsForeignControllerOwnerRevisionAndInvalidAnswerWithoutConsumingQuestion() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        let owner = try makeOwner(browser, planner: planner), original = owner.input
        let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        for bad in [
            ComputerUseBrowserQuestionRequest(taskID: "foreign", inputDigest: original.digest, topic: .date, requirementIDs: [proposal.requirements[0].id]),
            .init(taskID: original.taskID, inputDigest: String(repeating: "0", count: 64), topic: .date, requirementIDs: [proposal.requirements[0].id]),
            .init(taskID: original.taskID, inputDigest: original.digest, topic: .date, requirementIDs: ["unknown"]),
        ] {
            XCTAssertThrowsError(try bridge.issue(bad, owner: owner, for: request(original.taskID)))
        }
        let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .date,
            requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request(original.taskID))
        for answerEnvelope in [request("answer", sender: "other"), request("answer", session: "other"), request(original.taskID)] {
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: answerEnvelope, retainedOwner: { _ in owner }))
        }
        XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in nil }))
        let replacement = try makeOwner(browser, planner: planner)
        XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in replacement }))
        for invalid in ["", "  \n  ", String(repeating: "x", count: 8_193)] {
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: invalid, for: request("answer"), retainedOwner: { _ in owner }))
        }
        XCTAssertEqual(owner.input, original)
        XCTAssertTrue(bridge.retains(issued.reference, for: request(original.taskID)))
        _ = try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in owner })
        XCTAssertEqual(owner.input.userTurns, [original.prompt, "tomorrow"])
    }

    func testExpiredPausedRetiredOrInvalidatedBrowserQuestionCannotBeRevivedByWireReplay() async throws {
        for reason in ["expired", "paused", "retired", "invalidated"] {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
            defer { browser.close() }
            let owner = try makeOwner(browser, planner: planner, now: { now }), original = owner.input
            let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
            let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .quantity,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request(original.taskID))
            switch reason {
            case "expired": now = issued.reference.expiresAt
            case "paused": owner.pause(); try await owner.resumeAfterUserControl()
            case "retired": owner.retire()
            default: bridge.invalidate()
            }
            XCTAssertFalse(bridge.retains(issued.reference, for: request(original.taskID)))
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "two tickets", for: request("answer"), retainedOwner: { _ in owner }), reason)
            XCTAssertEqual(owner.input, original)
        }
    }

    func testAcceptedAnswerMapsOnlyCurrentExecutionToBrowserRootAndLifecycle() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser(); try? FileManager.default.removeItem(at: directory) }
        let owner = try tools.prepareOwnedBrowserResearch(taskID: "root", prompt: "Find concert tickets.", goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture())
        let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        let issued = try bridge.issue(.init(taskID: owner.taskID, inputDigest: owner.input.digest, topic: .location,
            requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request("root"))
        _ = try bridge.consume(issued.reference, answer: "Paris", for: request("answer"), retainedOwner: { tools.ownedBrowserResearch(taskID: $0) })
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "answer"), "root")
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "unrelated"), "unrelated")
        tools.pauseOwnedBrowserResearch(taskID: "root")
        tools.retireOwnedBrowserResearch(taskID: "root")
        _ = try await owner.interpretGoal()
        tools.pauseOwnedBrowserResearch(taskID: "answer")
        do { _ = try await owner.interpretGoal(); XCTFail("The accepted answer's Pause must reach its original owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await tools.resumeOwnedBrowserResearch(taskID: "answer")
        tools.retireOwnedBrowserResearch(taskID: "answer")
        do { _ = try await owner.interpretGoal(); XCTFail("The accepted answer's Stop must retire its original owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeOwner(_ browser: ComputerUseOwnedBrowser, planner: BrowserResearchGoalFixture,
                           prompt: String = "Find concert tickets.",
                           now: @escaping () -> Date = Date.init) throws -> ComputerUseBrowserResearchTask {
        let input = try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        return .init(input: input, browser: browser, goalPlanner: planner, resultPlanner: BrowserResearchResultFixture(), mayAct: { true }, now: now)
    }
    private func request(_ id: String, sender: String = "phone", session: String = "session", body: String = "") -> ComputerUseEnvelope {
        .init(id: id, senderID: sender, targetID: "host", pairingCode: "842193", sessionID: session, kind: .prompt, body: body)
    }
}

/// Shared by the host/phone composition fixtures. Only local task state and
/// decoded fake proposals are exercised; the default terminal claims no research result.
@MainActor
final class BrowserQuestionLifecycleExecutor: ComputerUseExecuting, ComputerUseBrowserResearchExecuting {
    let isReady = true
    let requiresMacControlHelper = false
    let runtimeName = "Prepared browser-question fixture"
    let planner = BrowserResearchGoalFixture()
    private(set) var owner: ComputerUseBrowserResearchTask?
    private(set) var ordinaryPrompts: [String] = []
    private(set) var continued: [(taskID: String, goal: ComputerUseBrowserGoalInput)] = []
    var pauseFirstAnswer = false
    var repeatLocationQuestions = false
    var initialQuestionTopic: ComputerUseBrowserClarificationTopic = .location
    var beforeQuestion: (() throws -> Void)?
    var preparePage: ((String) async throws -> Void)?

    /// Host/phone cases use the production capability wrapper around this
    /// controlled driver, so scoped answers cross the real routing boundary.
    func capabilityExecutor() -> ComputerUseCapabilityExecutor {
        .init(nativeExecution: { _, _, _ in nil }, desktopFactory: { _ in
            XCTFail("Retained research must not load desktop fallback")
            return self
        }, browserResearch: self)
    }

    func executeBrowserResearch(taskID: String, prompt: String, tools: ComputerUseHostTools,
                                progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        try await execute(taskID: taskID, prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: progress)
    }

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("The host must retain the original task identity")
        return .unableToComplete("Missing task identity")
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        ordinaryPrompts.append(trustedUserPrompt)
        let research = try tools.prepareOwnedBrowserResearch(taskID: taskID, prompt: trustedUserPrompt, goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture(), referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        owner = research
        if let preparePage { try await preparePage(research.taskID) }
        return try await next(research)
    }
    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask, tools: ComputerUseHostTools,
                                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTAssertTrue(research === owner)
        continued.append((taskID, research.input))
        if pauseFirstAnswer { pauseFirstAnswer = false; return .userInterventionRequired("Check the page, then choose Resume.") }
        return try await next(research)
    }
    private func next(_ research: ComputerUseBrowserResearchTask) async throws -> ComputerUseExecutionResult {
        planner.questionTopic = repeatLocationQuestions ? .location
            : research.input.userTurns.count < 3 ? (research.input.userTurns.count == 1 ? initialQuestionTopic : .date) : nil
        _ = try await research.interpretGoal()
        guard repeatLocationQuestions || research.input.userTurns.count < 3 else { return .unableToComplete("Fixture received the complete retained goal; no website research was performed.") }
        try beforeQuestion?()
        return .browserClarificationRequired(try XCTUnwrap(research.proposedQuestionRequest()))
    }
}

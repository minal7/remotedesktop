import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import RemoteDesktopClientCore

private enum GmailAcceptanceControlTrace {
    static func compactEvent(request: Data, response: Data) -> Data? {
        guard request.count <= 2 * 1_024 * 1_024, response.count <= 256 * 1_024,
              let requestRoot = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let messages = requestRoot["messages"] as? [[String: Any]],
              let user = messages.last(where: { $0["role"] as? String == "user" }),
              let content = user["content"] as? String,
              let context = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let responseRoot = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let choices = responseRoot["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let rawDecision = message["content"] as? String,
              let decision = try? JSONSerialization.jsonObject(with: Data(rawDecision.utf8)) as? [String: Any] else {
            return nil
        }
        let controls: [[String: Any]] = (context["native_controls"] as? [String: Any])?["items"] as? [[String: Any]]
            ?? context["observed_controls"] as? [[String: Any]] ?? []
        let safeControls = controls.prefix(48).map { item -> [String: Any] in
            var safe: [String: Any] = [:]
            for key in ["id", "role", "label", "enabled"] {
                if let value = item[key], value is String || value is NSNumber { safe[key] = value }
            }
            return safe
        }
        let safeDecision: [String: Any] = [
            "outcome": decision["outcome"] ?? NSNull(),
            "control_id": decision["control_id"] ?? NSNull(),
            "explanation": String((decision["explanation"] as? String ?? "").prefix(256)),
        ]
        return try? JSONSerialization.data(withJSONObject: [
            "observed_controls": safeControls,
            "control_count": controls.count,
            "decision": safeDecision,
            "request_bytes": request.count,
            "response_bytes": response.count,
            "focused_editor": context["focused_editor"] ?? NSNull(),
            "current_action_error": context["action_error"] ?? context["current_action_error"] ?? NSNull(),
        ], options: [.sortedKeys])
    }
}

@MainActor
final class CoreJobAcceptanceTests: XCTestCase {

    func testGmailAcceptanceAccountChoiceRequiresOneExactHostOfferedMatch() throws {
        let wanted = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-wanted",
            label: "Test Account", detail: "self@example.com")
        let other = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-other",
            label: "Other Account", detail: "other@example.com")
        XCTAssertEqual(Self.gmailAccountChoice(in: [other, wanted], expectedAddress: "self@example.com"), wanted)
        XCTAssertNil(Self.gmailAccountChoice(in: [wanted], expectedAddress: "self@example.com"),
            "A single option is not an observed account-choice list")
        let tooMany = try (0..<9).map { index in
            try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-\(index)",
                label: "Account \(index)", detail: "account\(index)@example.com")
        }
        XCTAssertNil(Self.gmailAccountChoice(in: tooMany, expectedAddress: "self@example.com"),
            "An overfull account list must not be auto-answered")
        let third = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-third",
            label: "Third Account", detail: "third@example.com")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, third], expectedAddress: "self@example.com"),
            "A valid account list without the expected address must not be answered")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, wanted, try RemoteDesktopClientCore.ComputerUseClarificationChoice(
            id: "gmail-account-duplicate", label: "Duplicate", detail: "self@example.com")],
            expectedAddress: "self@example.com"), "Ambiguous exact matches must not be answered automatically")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, try RemoteDesktopClientCore.ComputerUseClarificationChoice(
            id: "foreign-choice", label: "Self", detail: "self@example.com")],
            expectedAddress: "self@example.com"), "Matching display details do not authorize a foreign choice ID")
    }

    private struct Expected: Decodable {
        let job, run_id, prompt: String
        let source_path, source_sha256, attachment_name: String?
        let source_bytes: Int?
        let to, subject, body, cloud_root, destination_path: String?
        let gmail_existing_draft_url: String?
        let send_approval_check: Bool?
        let trip: Trip?
    }

    private struct Trip: Decodable {
        let origin, destination, date: String

        var json: [String: String] {
            ["origin": origin, "destination": destination, "date": date]
        }
    }

    func testRunJob() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let job = env["CORE_JOB_ACCEPTANCE_JOB"],
              let tracePath = env["CORE_JOB_ACCEPTANCE_TRACE"],
              let fixtureRoot = env["CORE_JOB_ACCEPTANCE_FIXTURE_ROOT"],
              let runID = env["CORE_JOB_ACCEPTANCE_RUN_ID"] else {
            throw XCTSkip("Opt-in: run_job.sh supplies the M0 job, trace, fixture root, and run ID")
        }
        let trace = URL(fileURLWithPath: tracePath, isDirectory: true)
        try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var record: [String: Any] = ["job": job, "run_id": runID, "task_id": NSNull(),
            "raw_outcome": "not-started", "text": "", "elapsed_ms": 0,
            "failure_class": NSNull(), "evidence": [String: Any]()]
        defer { try? Self.write(record, to: trace.appendingPathComponent("outcome.json")) }
        let started = Date()
        let expected: Expected
        do {
            expected = try JSONDecoder().decode(Expected.self,
                from: Data(contentsOf: trace.appendingPathComponent("expected.json")))
        } catch {
            record["failure_class"] = "other"
            record["text"] = "Could not read expected.json: \(error.localizedDescription.prefix(500))"
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
            throw error
        }
        guard expected.job == job, expected.run_id == runID,
              !expected.prompt.isEmpty, FileManager.default.fileExists(atPath: fixtureRoot) else {
            record["failure_class"] = "other"
            record["text"] = "The runner's expected.json or fixture root does not match this invocation"
            throw HarnessError.prerequisite("The runner's expected.json or fixture root does not match this invocation")
        }

        var manager: HostComputerUseManager?
        var client: RemoteDesktopClientCore.ComputerUseSessionModel?
        defer { client?.stop(); _ = manager?.stop() }

        do {
            if job == "email" || job == "cloud" || job == "gmail" {
                guard let sourcePath = expected.source_path, let sourceHash = expected.source_sha256,
                      try Self.sha256(URL(fileURLWithPath: sourcePath)) == sourceHash.lowercased() else {
                    throw HarnessError.prerequisite("The staged source does not match expected.json")
                }
            }
            let nativeInstaller = ComputerUseInstaller.nativeText()
            let nativeReceipt = await nativeInstaller.currentInstallation()
            let nativeInstallInterrupted = await nativeInstaller.interruptedInstallationExists()
            guard nativeReceipt != nil, !nativeInstallInterrupted else {
                throw HarnessError.prerequisite("Verified native text runtime is not ready; setup was not started")
            }
            let helperInstaller = MacControlMCPInstaller()
            guard case .ready = await helperInstaller.durableStatus() else {
                throw HarnessError.prerequisite("Verified MacControl helper is not ready; setup was not started")
            }

            let hostID = UUID().uuidString, clientID = UUID().uuidString
            let sessionID = UUID().uuidString, pairingCode = String(Int.random(in: 100_000...999_999))
            let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
            let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID,
                clientID: clientID, sessionID: sessionID, pairingCode: pairingCode)
            let pendingStore = CompositionPendingStore()
            let diagnosticLock = NSLock()
            let visualLoader: (any ComputerUseVisualExecutorLoading)? = job == "gmail"
                ? OSAtlasVisualExecutorLoader(nativeControlInspectExchange: { request, response in
                    guard let event = GmailAcceptanceControlTrace.compactEvent(request: request, response: response) else { return }
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-control-decisions.jsonl")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(event); data.append(0x0A)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }, browserRevalidationFailureObserver: { expected, fresh, action, diagnostic in
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-revalidation.jsonl")
                        let facts: [String: Any] = ["action": String(describing: action),
                            "diagnostic": diagnostic,
                            "expected_display_bounds": String(describing: expected.displayBounds),
                            "fresh_display_bounds": String(describing: fresh.displayBounds)]
                        guard let event = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) else { return }
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(event); data.append(0x0A)
                        try? Data(data.suffix(16_384)).write(to: path, options: .atomic)
                    }
                }, gmailExistingDraftURL: expected.gmail_existing_draft_url.flatMap { URL(string: $0) })
                : nil
            let host = HostComputerUseManager(injector: InputInjector(),
                nativeTextInstaller: nativeInstaller, macControlInstaller: helperInstaller,
                visualExecutorLoader: visualLoader,
                mcpPlanner: AppleFoundationMCPPlanner(inspectFailure: { message in
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("planner-failure.txt")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(contentsOf: (message + "\n").utf8)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }),
                taskLedger: ComputerUseTaskLedger(fileURL: trace.appendingPathComponent("ledger.json")),
                allowsExternalServices: true,
                nativeTextTargetDiagnosticObserver: { event in
                    guard job == "gmail", let eventData = try? JSONEncoder().encode(event) else { return }
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-text-bindings.jsonl")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(eventData); data.append(0x0A)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }, channelFactory: { _ in mailbox })
            manager = host
            let phone = RemoteDesktopClientCore.ComputerUseSessionModel(hostName: "M0 local host",
                pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
                pendingStore: pendingStore, channel: bridge, promptRefreshInterval: .seconds(600))
            client = phone

            host.start(pairingCode: pairingCode, additionalChannels: [mailbox], includeDefaultChannel: false)
            host.authorizePeer(senderID: clientID)
            phone.start()
            let ready = await Self.waitForReady(host, deadline: .now + .seconds(60))
            guard phone.sendPrompt(expected.prompt) else {
                throw HarnessError.transport("The shipped client refused the job prompt")
            }
            let taskID = try await Self.waitForSentPrompt(bridge, deadline: .now + .seconds(5))
            record["task_id"] = taskID
            record["raw_outcome"] = "running"
            let terminal = try await Self.waitForTerminal(phone, expected: expected,
                deadline: .now + .seconds(job == "gmail" ? 420 : 180), trace: trace)
            record["task_id"] = taskID
            record["raw_outcome"] = terminal.outcome
            record["text"] = String((phone.interventionGuidance
                ?? phone.messages.last(where: { $0.author == .assistant })?.text ?? phone.statusText).prefix(12_000))
            record["progress"] = phone.taskProgressHistory
            var evidence: [String: Any] = ["transport": "local-in-process", "manager_ready_before_prompt": ready,
                "dispatch_counts": ["client_prompt": 1, "native_inputs": NSNull()]]
        evidence["draft_create_approved_count"] = terminal.approvedDrafts
        evidence["other_approval_denied_count"] = terminal.deniedApprovals
            record["evidence"] = evidence
            switch job {
            case "email":
                var email: [String: Any] = ["send_effects": NSNull(),
                    "send_approval_observed": terminal.sendApprovalObserved]
                evidence["email"] = email
                do {
                    try await Self.exportDraft(expected: expected, trace: trace, evidence: &email)
                } catch {
                    evidence["email"] = email
                    record["evidence"] = evidence
                    throw error
                }
                evidence["email"] = email
            case "cloud":
                var cloud: [String: Any] = [:]
                evidence["cloud"] = cloud
                do {
                    try await Self.checkCloudCopy(expected: expected, evidence: &cloud)
                } catch {
                    evidence["cloud"] = cloud
                    record["evidence"] = evidence
                    throw error
                }
                evidence["cloud"] = cloud
            case "flights":
                var flights: [String: Any] = [:]
                if let trip = expected.trip {
                    flights["requested_trip"] = trip.json
                    flights["requested_trip_source"] = "runner expected.json"
                }
                evidence["flights"] = flights
                do {
                    try Self.captureFlightPage(text: record["text"] as? String ?? "",
                        trace: trace, evidence: &flights)
                } catch {
                    evidence["flights"] = flights
                    record["evidence"] = evidence
                    throw error
                }
                evidence["flights"] = flights
            case "away":
                evidence["away"] = ["transport": "local-in-process", "cellular_route_verified": false,
                    "display_asleep_verified": false, "locked_state_detected": NSNull(),
                    "unlock_resume_prompt_shown": false, "pre_unlock_effect_count": NSNull(),
                    "start_seconds": NSNull(), "approval_push_seconds": NSNull()]
            case "gmail":
                var gmail: [String: Any] = ["approval_events": terminal.approvalEvents,
                    "approval_events_omitted": terminal.approvalEventsOmitted,
                    "approval_responses_denied": terminal.deniedApprovals,
                    "harness_granted_approvals": terminal.approvedDrafts,
                    "approval_responses_granted": terminal.approvedDrafts,
                    "send_approval_observed": terminal.sendApprovalObserved,
                    "send_approval_fields_exact": terminal.sendApprovalFieldsExact,
                    "send_approval_count": terminal.sendApprovalObserved ? 1 : 0,
                    "attachment_bytes_verified": false]
                if expected.send_approval_check != true {
                    await Self.captureGmailDraft(expected: expected, evidence: &gmail, verifySavedDraft: true)
                }
                evidence["gmail"] = gmail
            default:
                throw HarnessError.prerequisite("Unknown M0 job: \(job)")
            }
            record["evidence"] = evidence
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
            if let failure = Self.failureClass(outcome: record["raw_outcome"] as? String,
                                               text: record["text"] as? String) {
                record["failure_class"] = failure
            } else {
                record["failure_class"] = NSNull()
            }
            record["evidence"] = evidence
        } catch {
            if job == "gmail" {
                var gmail: [String: Any] = ["attachment_bytes_verified": false]
                if expected.send_approval_check != true {
                    await Self.captureGmailDraft(expected: expected, evidence: &gmail)
                }
                var evidence = record["evidence"] as? [String: Any] ?? [:]
                evidence["gmail"] = gmail
                record["evidence"] = evidence
            }
            if let client {
                record["progress"] = client.taskProgressHistory
                if let outcome = client.latestTerminalOutcome { record["raw_outcome"] = outcome.rawValue }
                if let guidance = client.interventionGuidance, !guidance.isEmpty { record["text"] = guidance }
            }
            let terminalFailure = Self.failureClass(outcome: record["raw_outcome"] as? String,
                                                     text: record["text"] as? String)
            if let terminalFailure,
               (terminalFailure == "guard-rejected" || terminalFailure == "approval-needed"
                    || terminalFailure == "model-malformed" || terminalFailure == "text-entry") {
                record["failure_class"] = terminalFailure
            } else {
                record["failure_class"] = Self.failureClass(error: error)
            }
            if (record["text"] as? String)?.isEmpty != false {
                record["text"] = String(describing: error).prefix(1_000).description
            }
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
        }
        if let manager {
            await manager.shutdown()
            await OSAtlasLlamaRuntime.shared.shutdown()
        }
    }

    private enum HarnessError: LocalizedError {
        case prerequisite(String), transport(String), missingEvidence(String)
        var errorDescription: String? {
            switch self {
            case .prerequisite(let text), .transport(let text), .missingEvidence(let text): text
            }
        }
    }

    private struct Terminal {
        let outcome: String
        let approvedDrafts: Int
        let deniedApprovals: Int
        let sendApprovalObserved: Bool
        let sendApprovalFieldsExact: Bool
        let approvalEvents: [[String: Any]]
        let approvalEventsOmitted: Int
    }

    func testFailureClassSeparatesGeneratedToolSchemaFailuresFromHostGuardRejection() {
        let unable = RemoteDesktopClientCore.ComputerUseTerminalOutcome.unableToComplete.rawValue
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "The local planning request is invalid: Generated arguments for example_tool did not satisfy the tool schema: A generated string is shorter than its minimum length."),
            "model-malformed")
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "The local planning request is invalid: The selected file changed during validation."),
            "guard-rejected")
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "I couldn't complete that task: The app did not confirm the exact text edit. Check the field before continuing; the edit was not retried."),
            "text-entry")
    }

    private static func waitForReady(_ host: HostComputerUseManager,
        deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if host.capability.state == .ready { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return host.capability.state == .ready
    }

    private static func waitForSentPrompt(_ bridge: SerializedClarificationClientChannel,
        deadline: ContinuousClock.Instant) async throws -> String {
        while ContinuousClock.now < deadline {
            if let id = await bridge.prompts().last?.id { return id }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.transport("The serialized client did not publish the job prompt")
    }

    private static func waitForTerminal(_ client: RemoteDesktopClientCore.ComputerUseSessionModel,
        expected: Expected, deadline: ContinuousClock.Instant, trace: URL) async throws -> Terminal {
        var deniedApprovals = 0
        var approvalEvents: [[String: Any]] = []
        var approvalEventsOmitted = 0
        var lastObservation = ""
        var answeredGmailAccountClarifications = Set<String>()
        while ContinuousClock.now < deadline {
            let observation = String(describing: client.state) + client.statusText
                + client.taskProgressHistory.joined(separator: "\n")
            if observation != lastObservation {
                try Self.write(["state": String(describing: client.state), "status": client.statusText,
                    "terminal": client.latestTerminalOutcome?.rawValue ?? "",
                    "intervention": client.interventionGuidance ?? "",
                    "assistant": String(client.messages.last(where: { $0.author == .assistant })?.text.prefix(12_000) ?? ""),
                    "progress": client.taskProgressHistory],
                    to: trace.appendingPathComponent("client-state.json"))
                lastObservation = observation
            }
            if expected.job == "gmail", let expectedAddress = expected.to,
               case .answer(let reference, let validUntil) = client.composerMode,
               validUntil > Date(),
               let choices = client.clarificationChoices,
               let choice = Self.gmailAccountChoice(in: choices, expectedAddress: expectedAddress) {
                let clarificationKey = "\(reference.taskID):\(choice.id)"
                if !answeredGmailAccountClarifications.contains(clarificationKey),
                   client.sendClarificationChoice(choice.id) {
                    answeredGmailAccountClarifications.insert(clarificationKey)
                    try Self.write(["task_id": reference.taskID, "choice_id": choice.id,
                        "account_detail": choice.detail ?? "", "choice_count": choices.count,
                        "answer_sent": true], to: trace.appendingPathComponent("gmail-account-choice.json"))
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
            }
            if case .approvalRequired(let request) = client.state {
                let details = request.details ?? []
                let labels = details.map(\.label)
                let fields = Set(labels).count == labels.count
                    ? Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) }) : [:]
                let exactFields = fields["To"] == expected.to && fields["Subject"] == expected.subject
                    && fields["Message"] == expected.body && fields["Attachment 1"] == expected.source_path
                    && fields["CC"] == nil && fields["BCC"] == nil
                    && fields["Attachment 2"] == nil && fields["Attachment 3"] == nil
                    && fields["Attachment 4"] == nil && fields["Attachment 5"] == nil
                if expected.send_approval_check == true, expected.job == "email",
                   request.confirmLabel == "Send email", exactFields {
                    // Observe the exact approval and leave it pending. No
                    // approval response can grant permission to send.
                    return Terminal(outcome: "approvalRequired", approvedDrafts: 0,
                        deniedApprovals: deniedApprovals, sendApprovalObserved: true,
                        sendApprovalFieldsExact: true,
                        approvalEvents: approvalEvents, approvalEventsOmitted: approvalEventsOmitted)
                }
                let gmailSendMessage = fields["Message"] as? String ?? ""
                let gmailAttachmentPresentation = expected.attachment_name.map { name in
                    "\(name) (\(expected.source_bytes ?? -1) bytes)"
                }
                let gmailSendFieldsExact = request.confirmLabel == "Send email"
                    && fields["To"] == expected.to && fields["Subject"] == expected.subject
                    && gmailSendMessage.hasPrefix(expected.body ?? "")
                    && fields["Attachment"] == gmailAttachmentPresentation
                    && fields["CC"] == nil && fields["BCC"] == nil
                    && fields["Attachment 2"] == nil && fields["Attachment 3"] == nil
                    && fields["Attachment 4"] == nil && fields["Attachment 5"] == nil
                if expected.send_approval_check == true, expected.job == "gmail", gmailSendFieldsExact {
                    let event: [String: Any] = [
                        "request_id": request.requestID,
                        "task_id": request.taskID,
                        "confirm_label": request.confirmLabel ?? "",
                        "message": request.message,
                        "details": (request.details ?? []).map { ["label": $0.label, "value": $0.value] },
                    ]
                    return Terminal(outcome: "approvalRequired", approvedDrafts: 0,
                        deniedApprovals: deniedApprovals, sendApprovalObserved: true,
                        sendApprovalFieldsExact: true, approvalEvents: [event], approvalEventsOmitted: 0)
                }
                if expected.job == "gmail" {
                    if approvalEvents.count < 24 {
                        approvalEvents.append([
                            "request_id": request.requestID,
                            "task_id": request.taskID,
                            "confirm_label": request.confirmLabel ?? "",
                            "message": request.message,
                            "details": (request.details ?? []).map { ["label": $0.label, "value": $0.value] },
                        ])
                    } else {
                        approvalEventsOmitted += 1
                    }
                    try? Self.write(["events": approvalEvents, "omitted": approvalEventsOmitted],
                        to: trace.appendingPathComponent("gmail-approval-events.json"))
                }
                deniedApprovals += 1
                client.respondToApproval(request, approved: false)
            }
            if let outcome = client.latestTerminalOutcome,
               !client.hasActivePrompt || outcome == .userInterventionRequired {
                return Terminal(outcome: outcome.rawValue, approvedDrafts: 0,
                    deniedApprovals: deniedApprovals, sendApprovalObserved: false,
                    sendApprovalFieldsExact: false,
                    approvalEvents: approvalEvents, approvalEventsOmitted: approvalEventsOmitted)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.transport("Timed out waiting for the shipped client terminal outcome")
    }

    private static func gmailAccountChoice(in choices: [RemoteDesktopClientCore.ComputerUseClarificationChoice],
                                           expectedAddress: String) -> RemoteDesktopClientCore.ComputerUseClarificationChoice? {
        guard (2...RemoteDesktopClientCore.ComputerUseClarificationChoice.maximumChoices).contains(choices.count),
              !expectedAddress.isEmpty,
              choices.allSatisfy({ $0.id.hasPrefix("gmail-account-") }) else { return nil }
        let matches = choices.filter { $0.detail?.utf8.elementsEqual(expectedAddress.utf8) == true }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func captureGmailDraft(expected: Expected, evidence: inout [String: Any],
                                          verifySavedDraft: Bool = false) async {
        guard let name = expected.attachment_name, let recipient = expected.to,
              let subject = expected.subject, let body = expected.body else {
            evidence["capture_status"] = "missing-expected-gmail-fields"
            return
        }
        var captured: (ComputerUseApplicationIdentity, ComputerUseDefaultBrowserSession.Window,
                       ComputerUseDefaultBrowserPageReader.Observation)?
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < loadDeadline, !Task.isCancelled {
            if let (_, application, _) = ComputerUseDefaultBrowserTarget.currentDefaultHandlerForegroundWindow(),
               let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
               let focusedID = snapshot.focusedWindowID,
               let window = snapshot.windows.first(where: { $0.id == focusedID }),
               let page = try? ComputerUseDefaultBrowserPageReader().read(window: window.accessibilityElement,
                    application: application, mayAct: { true }),
               page.application == application,
               URLComponents(string: page.url)?.host?.lowercased() == "mail.google.com" {
                captured = (application, window, page)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let (application, window, page) = captured else {
            evidence["capture_status"] = "no-focused-default-browser-page"
            return
        }
        let host = URLComponents(string: page.url)?.host?.lowercased() ?? ""
        evidence["browser_bundle_id"] = application.bundleIdentifier
        evidence["url_host"] = host
        evidence["compose_url"] = page.url
        evidence["url_is_gmail"] = host == "mail.google.com"
        guard host == "mail.google.com" else {
            evidence["capture_status"] = "focused-page-is-not-gmail"
            return
        }
        func value(_ attribute: String, _ element: AXUIElement) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, 0.1)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        struct Node {
            let element: AXUIElement
            let role, title, description, text: String
        }
        func readTree(_ root: AXUIElement, limit: Int) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var result: [Node] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !queue.isEmpty, visited.count < limit, ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                let text = value(kAXValueAttribute as String, element) as? String ?? ""
                result.append(Node(element: element, role: role, title: title, description: description, text: text))
                if role == "AXSheet" || role == "AXDialog" { continue }
                if let children = value(kAXChildrenAttribute as String, element) as? [AXUIElement] {
                    let room = max(0, limit - visited.count - queue.count)
                    guard children.count <= room else { return nil }
                    queue.append(contentsOf: children)
                }
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            return result
        }
        func discoverComposers(_ root: AXUIElement) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var composers: [Node] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !queue.isEmpty, visited.count < 256, ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                let text = value(kAXValueAttribute as String, element) as? String ?? ""
                if role == "AXGroup" && (title.hasPrefix("Compose:") || description.hasPrefix("Compose:")) {
                    composers.append(Node(element: element, role: role, title: title, description: description, text: text))
                    continue
                }
                // Gmail's inbox is an AXTable; its thousands of rows are unrelated to this owned compose.
                if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
                if let children = value(kAXChildrenAttribute as String, element) as? [AXUIElement] {
                    let room = max(0, 256 - visited.count - queue.count)
                    guard children.count <= room else { return nil }
                    queue.append(contentsOf: children)
                }
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            return composers
        }
        guard let composers = discoverComposers(window.accessibilityElement) else {
            evidence["capture_status"] = "accessibility-tree-incomplete"
            return
        }
        evidence["compose_count"] = composers.count
        var nodes: [Node] = []
        if composers.count == 1, let composer = composers.first,
           let composeNodes = readTree(composer.element, limit: 256) {
            nodes = composeNodes
        } else if !(verifySavedDraft && composers.isEmpty) {
            evidence["capture_status"] = "compose-window-not-unique-or-readable"
            return
        }
        let recipientContainer = nodes.first {
            ($0.role == "AXGroup" || $0.role == "AXTextField") && ($0.title == "To" || $0.description == "To")
        }
        let recipientNodes = recipientContainer.flatMap { readTree($0.element, limit: 64) } ?? []
        var recipientMatches = recipientNodes.contains {
            $0.role == "AXStaticText" && [$0.title, $0.description, $0.text].contains(recipient)
        }
        if !recipientMatches, !composers.isEmpty {
            // A collapsed contact chip is not always exposed beneath a To group.
            // Restrict fallback discovery to the subject field's parent inside
            // this unique compose group, then use only an advertised AXShowMenu.
            let subjectField = nodes.first { $0.role == "AXTextField" && $0.title == "Subject" }
            var subjectParent: AXUIElement?
            if let subjectField {
                var parent: CFTypeRef?
                if AXUIElementCopyAttributeValue(subjectField.element, kAXParentAttribute as CFString, &parent) == .success,
                   let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    subjectParent = (parent as! AXUIElement)
                }
            }
            let chipScope = recipientContainer?.element ?? subjectParent
            let chipNodes = chipScope.flatMap { readTree($0, limit: 64) } ?? []
            func supportsShowMenu(_ element: AXUIElement) -> Bool {
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      let actions = actions as? [String] else { return false }
                return actions.contains("AXShowMenu")
            }
            let chip = chipNodes.first {
                $0.role == "AXStaticText" && !$0.text.isEmpty && $0.text != subject && supportsShowMenu($0.element)
            }
            if let chip, let chipScope,
               AXUIElementPerformAction(chip.element, "AXShowMenu" as CFString) == .success {
                try? await Task.sleep(for: .milliseconds(120))
                let menuNodes = readTree(chipScope, limit: 128) ?? []
                let copyLabel = "Copy \"\(recipient)\""
                recipientMatches = menuNodes.contains {
                    $0.role == "AXMenuItem" && [$0.title, $0.description, $0.text].contains(where: {
                        $0 == copyLabel || $0 == "\(copyLabel) Option+C"
                    })
                }
                if let menu = menuNodes.first(where: { $0.role == "AXMenu" }) {
                    _ = AXUIElementPerformAction(menu.element, "AXCancel" as CFString)
                }
            }
        }
        let subjectMatches = nodes.contains { $0.role == "AXTextField" && $0.title == "Subject" && $0.text == subject }
        let bodyMatches = nodes.contains {
            ($0.role == "AXTextArea" || $0.role == "AXTextEntryArea") && $0.title == "Message Body" && $0.text == body
        }
        let attachmentGroups = nodes.filter {
            $0.role == "AXGroup" && ($0.title + $0.description + $0.text).contains("Attachment:")
                && ($0.title + $0.description + $0.text).contains("delete to remove it")
        }
        let expectedAttachmentGroups = attachmentGroups.filter {
            ($0.title + $0.description + $0.text).contains("Attachment: \(name).")
        }
        let attachmentGroup = attachmentGroups.count == 1 && expectedAttachmentGroups.count == 1
            ? expectedAttachmentGroups.first : nil
        let attachmentNodes = attachmentGroup.flatMap { readTree($0.element, limit: 64) } ?? []
        let attachmentNameVisible = attachmentNodes.contains {
            $0.role == "AXLink" && [$0.title, $0.description, $0.text].contains(where: {
                $0 == name || $0.hasPrefix("\(name) (")
            })
        }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        let sizeLabel = formatter.string(fromByteCount: Int64(expected.source_bytes ?? 0))
        let attachmentSizeVisible = (attachmentNodes + (attachmentGroup.map { [$0] } ?? [])).contains {
            ($0.title + $0.description + $0.text).contains(sizeLabel)
        }
        evidence["recipient_matches"] = recipientMatches
        evidence["subject_matches"] = subjectMatches
        evidence["body_matches"] = bodyMatches
        evidence["attachment_name_visible"] = attachmentNameVisible
        evidence["attachment_count"] = attachmentGroups.count
        evidence["attachment_size_label"] = sizeLabel
        evidence["attachment_size_visible"] = attachmentSizeVisible
        evidence["attachment_bytes_verified"] = false
        evidence["saved_marker_observed"] = nodes.contains {
            ($0.title + $0.description + $0.text).localizedCaseInsensitiveContains("Draft saved")
        }
        evidence["capture_status"] = composers.isEmpty ? "compose-already-closed" : "captured"
        guard verifySavedDraft else { return }
        func press(_ element: AXUIElement) -> Bool {
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            value(kAXChildrenAttribute as String, element) as? [AXUIElement] ?? []
        }
        func findOwnedDraftSubject(_ root: AXUIElement, subject: String) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var matches: [Node] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !queue.isEmpty, visited.count < 1_800, ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                let text = value(kAXValueAttribute as String, element) as? String ?? ""
                let candidate = (role == "AXStaticText" && [title, description, text].contains(subject))
                    || (role == "AXCell" && [title, description, text].contains(subject))
                    || (role == "AXRow" && [title, description, text].contains(where: { $0.contains(subject) }))
                if candidate {
                    matches.append(Node(element: element, role: role, title: title,
                        description: description, text: text))
                }
                if role == "AXSheet" || role == "AXDialog" { continue }
                let next = children(element)
                let room = max(0, 1_800 - visited.count - queue.count)
                guard next.count <= room else { return nil }
                queue.append(contentsOf: next)
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }

            // Several AX nodes can expose the same row's subject. Collapse by
            // the actionable row when present, otherwise retain the exact text node.
            var rows: [Node] = []
            for match in matches {
                var current: AXUIElement? = match.element
                var row: AXUIElement?
                for _ in 0..<8 {
                    guard let element = current else { break }
                    let currentRole = value(kAXRoleAttribute as String, element) as? String ?? ""
                    if currentRole == "AXRow" { row = element; break }
                    var parent: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                          let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    current = (parent as! AXUIElement)
                }
                let actionable = row ?? match.element
                guard !rows.contains(where: { CFEqual($0.element, actionable) }) else { continue }
                let role = value(kAXRoleAttribute as String, actionable) as? String ?? match.role
                let title = value(kAXTitleAttribute as String, actionable) as? String ?? match.title
                let description = value(kAXDescriptionAttribute as String, actionable) as? String ?? match.description
                let text = value(kAXValueAttribute as String, actionable) as? String ?? match.text
                rows.append(Node(element: actionable, role: role, title: title,
                    description: description, text: text))
            }
            return rows
        }
        if composers.count == 1 {
            guard let saveClose = nodes.first(where: {
                $0.role == "AXButton" && [$0.title, $0.description].contains("Save & close")
            }), press(saveClose.element) else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "save-close-control-unavailable"
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
        }

        // Search only browser chrome/navigation for Drafts; never traverse the inbox table.
        var chromeQueue = [window.accessibilityElement]
        var chromeSeen: [AXUIElement] = []
        var chromeNodes: [Node] = []
        let chromeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !chromeQueue.isEmpty, chromeSeen.count < 256, ContinuousClock.now < chromeDeadline,
              !Task.isCancelled {
            let element = chromeQueue.removeFirst()
            guard !chromeSeen.contains(where: { CFEqual($0, element) }) else { continue }
            chromeSeen.append(element)
            let role = value(kAXRoleAttribute as String, element) as? String ?? ""
            let title = value(kAXTitleAttribute as String, element) as? String ?? ""
            let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
            let text = value(kAXValueAttribute as String, element) as? String ?? ""
            chromeNodes.append(Node(element: element, role: role, title: title, description: description, text: text))
            if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
            let next = children(element)
            let room = max(0, 256 - chromeSeen.count - chromeQueue.count)
            guard next.count <= room else { break }
            chromeQueue.append(contentsOf: next)
        }
        let draftsLabel = chromeNodes.first {
            [$0.title, $0.description, $0.text].contains(where: { $0 == "Drafts" || $0.hasPrefix("Drafts ") })
        }
        var draftsNavigation: AXUIElement?
        var draftsAncestor: AXUIElement? = draftsLabel?.element
        for _ in 0..<6 {
            guard let current = draftsAncestor else { break }
            let role = value(kAXRoleAttribute as String, current) as? String ?? ""
            if role == "AXLink" || role == "AXButton" || role == "AXRow" || role == "AXMenuItem" {
                draftsNavigation = current
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            draftsAncestor = (parent as! AXUIElement)
        }
        guard let draftsNavigation, press(draftsNavigation) else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "drafts-navigation-unavailable"
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard let subjectNodes = findOwnedDraftSubject(window.accessibilityElement, subject: subject) else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "drafts-list-incomplete"
            return
        }
        evidence["saved_draft_count"] = subjectNodes.count
        guard subjectNodes.count == 1, let subjectNode = subjectNodes.first else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-subject-not-unique-in-drafts"
            return
        }
        var draftRow: AXUIElement?
        var ancestor: AXUIElement? = subjectNode.element
        for _ in 0..<8 {
            guard let current = ancestor else { break }
            let role = value(kAXRoleAttribute as String, current) as? String ?? ""
            if role == "AXRow" || role == "AXLink" || role == "AXButton" {
                draftRow = current
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success else { break }
            guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = (parent as! AXUIElement)
        }
        guard let draftRow, press(draftRow) else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-draft-row-not-actionable"
            return
        }
        var reopened = false
        let reopenDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < reopenDeadline, !Task.isCancelled {
            if let found = discoverComposers(window.accessibilityElement), found.count == 1 {
                reopened = true
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard reopened else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-draft-did-not-reopen"
            return
        }
        var savedFields: [String: Any] = [:]
        await Self.captureGmailDraft(expected: expected, evidence: &savedFields)
        evidence["saved_draft_url"] = savedFields["compose_url"] ?? NSNull()
        evidence["saved_to_matches"] = savedFields["recipient_matches"] ?? false
        evidence["saved_subject_matches"] = savedFields["subject_matches"] ?? false
        evidence["saved_body_matches"] = savedFields["body_matches"] ?? false
        evidence["saved_attachment_name_visible"] = savedFields["attachment_name_visible"] ?? false
        evidence["saved_attachment_size_visible"] = savedFields["attachment_size_visible"] ?? false
        evidence["saved_attachment_count"] = savedFields["attachment_count"] ?? 0
        evidence["draft_saved_verified"] = subjectNodes.count == 1
            && (savedFields["attachment_count"] as? Int == 1)
            && (savedFields["url_is_gmail"] as? Bool == true)
            && (savedFields["recipient_matches"] as? Bool == true)
            && (savedFields["subject_matches"] as? Bool == true)
            && (savedFields["body_matches"] as? Bool == true)
            && (savedFields["attachment_name_visible"] as? Bool == true)
            && (savedFields["attachment_size_visible"] as? Bool == true)
        evidence["saved_oracle_status"] = evidence["draft_saved_verified"] as? Bool == true
            ? "reopened-from-drafts" : "reopened-draft-fields-mismatch"
    }

    private static func exportDraft(expected: Expected, trace: URL,
        evidence: inout [String: Any]) async throws {
        guard let subject = expected.subject else { throw HarnessError.missingEvidence("Missing expected draft subject") }
        let script = #"""
        const Mail = Application("/System/Applications/Mail.app");
        function run(argv) {
            const wanted = argv[0];
            const drafts = Mail.draftsMailbox.messages.whose({subject: wanted})();
            const open = Mail.outgoingMessages.whose({subject: wanted})();
            const sent = Mail.sentMailbox.messages.whose({subject: wanted})();
            const visible = open.length === 1 && open[0].visible() === true;
            const source = drafts.length === 1 ? drafts[0].source() : null;
            return JSON.stringify({draft_count: drafts.length, visible_count: open.length,
                visible: visible, sent_count: sent.length, source: source});
        }
        """#
        let queryURL = trace.appendingPathComponent("mail-query.json")
        let errorURL = trace.appendingPathComponent("mail-query-stderr.txt")
        try? FileManager.default.removeItem(at: queryURL)
        try? FileManager.default.removeItem(at: errorURL)
        guard FileManager.default.createFile(atPath: queryURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw HarnessError.missingEvidence("Could not create a private Mail query file")
        }
        defer { try? FileManager.default.removeItem(at: queryURL) }
        evidence["mail_query_stderr_path"] = errorURL.path
        let deadline = ContinuousClock.now + .seconds(15)
        var json: [String: Any]?
        var queryError: String?
        while ContinuousClock.now < deadline {
            let output = try FileHandle(forWritingTo: queryURL)
            let errors = try FileHandle(forWritingTo: errorURL)
            try output.truncate(atOffset: 0); try errors.truncate(atOffset: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script, subject]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            while process.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                let stopDeadline = ContinuousClock.now + .seconds(1)
                while process.isRunning && ContinuousClock.now < stopDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            try output.close(); try errors.close()
            guard !process.isRunning else { throw HarnessError.transport("Mail MIME query exceeded its deadline") }
            let bytes = try Data(contentsOf: queryURL)
            if process.terminationStatus != 0 {
                queryError = String(decoding: try Data(contentsOf: errorURL).prefix(1_000), as: UTF8.self)
                break
            }
            if let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                json = result
                if expected.send_approval_check == true || (result["draft_count"] as? Int ?? 0) > 0
                    || (result["sent_count"] as? Int ?? 0) > 0 { break }
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard let json,
              let draftCount = json["draft_count"] as? Int,
              let visibleCount = json["visible_count"] as? Int,
              let sentCount = json["sent_count"] as? Int else {
            throw HarnessError.missingEvidence("Independent Mail Drafts source/visibility query failed: \(queryError ?? "no Mail record appeared within 15 seconds")")
        }
        evidence["draft_subject"] = subject
        evidence["draft_count"] = draftCount
        evidence["draft_visible_count"] = (json["visible"] as? Bool == true) ? visibleCount : 0
        evidence["send_effects"] = sentCount
        if expected.send_approval_check == true {
            guard sentCount == 0 else { throw HarnessError.missingEvidence("The Send approval was bypassed") }
            return
        }
        guard draftCount == 1, visibleCount == 1, json["visible"] as? Bool == true,
              sentCount == 0, let source = json["source"] as? String else {
            throw HarnessError.missingEvidence("Mail did not retain exactly one visible unsent draft; sent_matches=\(sentCount)")
        }
        let mimeURL = trace.appendingPathComponent("mail-source.eml")
        try Data(source.utf8).write(to: mimeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mimeURL.path)
        evidence["draft_mime_source_path"] = mimeURL.path
        evidence["mime_checker"] = "independent-python"
        try Self.write(["draft_count": 1, "draft_visible_count": 1, "visible_count": 1,
            "sent_count": 0, "subject": subject,
            "mime_source_path": mimeURL.path], to: trace.appendingPathComponent("mail-oracle.json"))
    }

    private static func checkCloudCopy(expected: Expected,
        evidence: inout [String: Any]) async throws {
        guard let sourcePath = expected.source_path, let targetPath = expected.destination_path,
              let expectedDigest = expected.source_sha256 else {
            throw HarnessError.missingEvidence("Cloud expected.json lacks source or destination")
        }
        var target = URL(fileURLWithPath: targetPath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw HarnessError.missingEvidence("Cloud destination file was not copied")
        }
        if let cloudRoot = expected.cloud_root {
            let root = URL(fileURLWithPath: cloudRoot).standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(root + "/") else {
                throw HarnessError.missingEvidence("Cloud destination is outside the selected sync root")
            }
        }
        var uploaded: Bool?
        var uploading: Bool?
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        repeat {
            target.removeAllCachedResourceValues()
            let values = try? target.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            uploaded = values?.ubiquitousItemIsUploaded
            uploading = values?.ubiquitousItemIsUploading
            if uploaded == true || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: min(.seconds(2), ContinuousClock.now.duration(to: deadline)))
        } while true
        let sourceDigest = try Self.sha256(URL(fileURLWithPath: sourcePath))
        let destinationDigest = try Self.sha256(target)
        guard sourceDigest == expectedDigest.lowercased(), destinationDigest == sourceDigest else {
            throw HarnessError.missingEvidence("Cloud copy SHA-256 does not match the staged source")
        }
        evidence["source_sha256"] = sourceDigest
        evidence["destination_path"] = target.path
        evidence["destination_sha256"] = destinationDigest
        evidence["provider_uploaded"] = uploaded as Any? ?? NSNull()
        evidence["provider_uploading"] = uploading as Any? ?? NSNull()
        evidence["uploaded"] = uploaded == true
        evidence["upload_state"] = uploaded == true ? "uploaded"
            : (uploaded == nil && uploading == nil ? "unknown" : "pending")
    }

    private static func captureFlightPage(text: String, trace: URL,
        evidence: inout [String: Any]) throws {
        guard let (_, application, _) = ComputerUseDefaultBrowserTarget.currentDefaultHandlerForegroundWindow(),
              let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
              let focusedID = snapshot.focusedWindowID,
              let window = snapshot.windows.first(where: { $0.id == focusedID }),
              let page = try ComputerUseDefaultBrowserPageReader().read(window: window.accessibilityElement,
                application: application, mayAct: { true }),
              page.application == application, URL(string: page.url)?.scheme?.lowercased() == "https" else {
            throw HarnessError.missingEvidence("Could not independently read the foreground default-browser page")
        }
        let pageURL = trace.appendingPathComponent("flight-page.txt")
        try Data(page.renderedAXText.utf8).write(to: pageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
        evidence["page_url"] = page.url
        evidence["url"] = page.url
        evidence["page_text_path"] = pageURL.path
        evidence["page_text"] = page.renderedAXText
        evidence["prices"] = Self.priceStrings(in: text)
        evidence["browser_bundle_id"] = application.bundleIdentifier
    }

    private static func priceStrings(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9])(?:USD\s*)?\$\s?\d[\d,]*(?:\.\d{2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureClass(outcome: String?, text: String?) -> String? {
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.taskCompleted.rawValue { return nil }
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.userInterventionRequired.rawValue { return "approval-needed" }
        if text?.localizedCaseInsensitiveContains("The app did not confirm the exact text edit") == true
            || text?.localizedCaseInsensitiveContains("text entry was not confirmed") == true {
            return "text-entry"
        }
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.unableToComplete.rawValue {
            if text?.contains("Generated arguments for ") == true,
               text?.contains(" did not satisfy the tool schema:") == true {
                return "model-malformed"
            }
            if text?.contains("The local planning request is invalid:") == true {
                return "guard-rejected"
            }
        }
        return "other"
    }

    private static func failureClass(error: Error) -> String {
        if case HarnessError.transport(_) = error { return "timeout" }
        return "other"
    }

    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

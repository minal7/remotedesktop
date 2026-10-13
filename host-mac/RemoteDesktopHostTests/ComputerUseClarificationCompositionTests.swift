import AppKit
import XCTest
@testable import RemoteDesktopHost
@testable import RemoteDesktopClientCore

typealias ClientModel = RemoteDesktopClientCore.ComputerUseSessionModel
typealias ClientEnvelope = RemoteDesktopClientCore.ComputerUseEnvelope
typealias HostEnvelope = RemoteDesktopHost.ComputerUseEnvelope
typealias ClientUpdate = RemoteDesktopClientCore.ComputerUseTaskUpdate

@MainActor
final class ComputerUseClarificationCompositionTests: XCTestCase {
    func testShippedClientAnswersGenericQuestionsWithoutReplacingOriginalGoal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let executor = ScopedClarificationTestExecutor()
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), allowsExternalServices: false,
            channelFactory: { _ in mailbox })
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID)
        client.start()
        let original = "Find concert tickets. Do not purchase anything."
        let turns = [original, "  Paris e\u{301} 😀\n  ", "2026-10-15"]
        var reference: RemoteDesktopClientCore.ComputerUseClarificationReference?
        var sentIDs: [String] = []
        for (index, text) in turns.enumerated() {
            XCTAssertTrue(client.sendPrompt(text))
            try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
            let prompts = await bridge.prompts(), sent = try XCTUnwrap(prompts.last)
            sentIDs.append(sent.id)
            let request = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
            XCTAssertEqual(request.clarification, reference)
            XCTAssertTrue(request.prompt.utf8.elementsEqual(text.utf8))
            XCTAssertTrue(request.conversation.isEmpty)
            let delivered = await bridge.terminals(taskID: sent.id)
            let terminal = try XCTUnwrap(delivered.last)
            if index < turns.count - 1 {
                guard case .answer(let next, _) = client.composerMode else {
                    return XCTFail("The shipped client must receive the generic host question")
                }
                XCTAssertEqual(terminal.outcome, .userInterventionRequired)
                XCTAssertEqual(next.taskID, sent.id)
                reference = next
            } else {
                XCTAssertEqual(client.composerMode, .request)
                XCTAssertEqual(terminal.outcome, .taskCompleted)
            }
            let before = await bridge.terminals(taskID: sent.id).count
            try await bridge.replay(sent)
            try await pumpHost(manager, mailbox: mailbox) { await bridge.terminals(taskID: sent.id).count > before }
            XCTAssertEqual(executor.normalPrompts, [original])
            XCTAssertEqual(executor.answers.count, index)
            if let goal = executor.answers.last?.goal {
                XCTAssertEqual(goal.userTurns.count, index + 1)
                XCTAssertEqual(executor.answers.last?.origin, sentIDs[index - 1])
                XCTAssertEqual(executor.answers.last?.taskID, sent.id)
                XCTAssertTrue(goal.userTurns.first?.utf8.elementsEqual(original.utf8) == true)
                XCTAssertTrue(zip(goal.userTurns, turns.prefix(index + 1)).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
            }
        }
        XCTAssertEqual(Set(sentIDs).count, turns.count)
        XCTAssertEqual(executor.effects, 1)
    }

    func testCurrentClientCapabilityPassesHostAdmissionAcrossScopedAnswersAndDurableReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let executor = ScopedClarificationTestExecutor()
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), allowsExternalServices: false,
            channelFactory: { _ in mailbox })
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID)
        client.start()
        let original = "Put \"  e\u{301} 😀\n" + String(repeating: "x", count: 5_000) + "  \" in a field."
        let turns = [original, "  東京 e\u{301} 😀\n  ", "International"]
        var previousReference: RemoteDesktopClientCore.ComputerUseClarificationReference?
        var sentIDs: [String] = []
        for (index, text) in turns.enumerated() {
            XCTAssertTrue(client.sendPrompt(text))
            try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
            let sentPrompts = await bridge.prompts()
            let sent = try XCTUnwrap(sentPrompts.last)
            sentIDs.append(sent.id)
            let admitted = try RemoteDesktopHost.ComputerUseExecutionPromptDecoder.decode(sent.body)
            XCTAssertTrue(admitted.supportsApprovedActionEvidence, "Use the actual shipped client payload, not a default-false hand-built request")
            XCTAssertTrue(admitted.prompt.utf8.elementsEqual(text.utf8))
            let clientRequest = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
            XCTAssertEqual(clientRequest.clarification, previousReference)
            XCTAssertTrue(clientRequest.conversation.isEmpty)
            XCTAssertEqual(executor.normalPrompts, [original])
            XCTAssertEqual(executor.answers.count, index)
            let delivered = await bridge.terminals(taskID: sent.id)
            let terminal = try XCTUnwrap(delivered.last)
            if index < turns.count - 1 {
                guard case .answer(let reference, _) = client.composerMode else {
                    return XCTFail("The real client must receive the host's scoped question")
                }
                XCTAssertEqual(reference, terminal.clarification)
                XCTAssertEqual(terminal.outcome, .userInterventionRequired)
                previousReference = reference
                XCTAssertEqual(executor.effects, 0)
            } else {
                XCTAssertEqual(client.composerMode, .request)
                XCTAssertEqual(terminal.outcome, .taskCompleted)
                XCTAssertNil(terminal.clarification)
                XCTAssertEqual(executor.effects, 1, "Only the controlled executor counter is an effect in this fixture")
            }
            let before = await bridge.terminals(taskID: sent.id).count
            try await bridge.replay(sent)
            try await pumpHost(manager, mailbox: mailbox) { await bridge.terminals(taskID: sent.id).count > before }
            let replayed = await bridge.terminals(taskID: sent.id)
            let replay = try XCTUnwrap(replayed.last)
            XCTAssertEqual(replay, terminal)
            XCTAssertEqual(executor.normalPrompts.count, 1)
            XCTAssertEqual(executor.answers.count, index, "A replay must not repeat clarification continuation")
        }
        XCTAssertEqual(Set(sentIDs).count, turns.count)
        let retained = try XCTUnwrap(executor.answers.last?.goal.userTurns)
        XCTAssertEqual(retained.count, turns.count)
        XCTAssertTrue(zip(retained, turns).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
        XCTAssertEqual(executor.effects, 1)
    }


    private func pumpHost(_ manager: HostComputerUseManager, mailbox: LocalHostComputerUseChannel,
                          until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CompositionFailure.incomplete("Timed out waiting for client/host wire composition") }
            let incoming = try await mailbox.poll()
            var accepted: [HostEnvelope] = []
            for envelope in incoming where manager.handle(envelope, channel: mailbox) { accepted.append(envelope) }
            try await mailbox.acknowledge(accepted)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

private enum CompositionFailure: Error { case incomplete(String) }

/// Only the transport adapter is controlled. Both endpoints compile their own
/// production wire types and exchange JSON bytes; no cross-module cast can hide
/// a serialization mismatch. LocalHostComputerUseChannel performs real routing
/// and mailbox validation, but this fixture makes no claim about TLS enrollment.
actor SerializedClarificationClientChannel: RemoteDesktopClientCore.ComputerUseSessionChannel {
    let mailbox: LocalHostComputerUseChannel
    let hostID: String, clientID: String, sessionID: String, pairingCode: String
    private var sentPrompts: [ClientEnvelope] = []
    private var receivedTerminals: [String: [ClientUpdate]] = [:]
    private var receivedApprovals: [RemoteDesktopHost.ComputerUseApprovalRequest] = []
    private var seen = Set<String>()
    init(mailbox: LocalHostComputerUseChannel, hostID: String, clientID: String, sessionID: String, pairingCode: String) {
        self.mailbox = mailbox; self.hostID = hostID; self.clientID = clientID
        self.sessionID = sessionID; self.pairingCode = pairingCode
    }
    func send(kind: ClientEnvelope.Kind, body: String, to target: String?, sessionID session: String?, messageID: String?) async throws -> ClientEnvelope {
        let envelope = ClientEnvelope(id: messageID ?? UUID().uuidString, senderID: clientID, targetID: target ?? hostID,
            pairingCode: pairingCode, sessionID: session ?? sessionID, kind: kind, body: body)
        try await replay(envelope)
        if kind == .prompt { sentPrompts.append(envelope) }
        return envelope
    }
    func replay(_ envelope: ClientEnvelope) async throws {
        let decoded = try JSONDecoder().decode(HostEnvelope.self, from: JSONEncoder().encode(envelope))
        try await mailbox.receiveFromClient(decoded, authenticatedSenderID: clientID)
    }
    func poll() async throws -> [ClientEnvelope] {
        let outgoing = try await mailbox.pollForClient(authenticatedSenderID: clientID, sessionID: sessionID)
        let decoded = try JSONDecoder().decode([ClientEnvelope].self, from: JSONEncoder().encode(outgoing))
        for envelope in decoded where seen.insert(envelope.id).inserted {
            if envelope.kind == .assistant {
                let update = try ClientUpdate.decodeBody(envelope.body)
                if update.outcome != nil { receivedTerminals[update.taskID, default: []].append(update) }
            } else if envelope.kind == .approvalRequest,
                      let approval = try? RemoteDesktopHost.ComputerUseApprovalRequest.decodeBody(envelope.body) {
                receivedApprovals.append(approval)
            }
        }
        return decoded
    }
    func acknowledge(_ envelopes: [ClientEnvelope]) async throws {
        try await mailbox.acknowledgeFromClient(ids: envelopes.map(\.id), authenticatedSenderID: clientID, sessionID: sessionID)
    }
    func prompts() -> [ClientEnvelope] { sentPrompts }
    func terminals(taskID: String) -> [ClientUpdate] { receivedTerminals[taskID] ?? [] }
    func approvals() -> [RemoteDesktopHost.ComputerUseApprovalRequest] { receivedApprovals }
}

final class CompositionPendingStore: RemoteDesktopClientCore.ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteDesktopClientCore.ComputerUsePendingPrompt?
    func load(hostID: String, pairingCode: String) -> RemoteDesktopClientCore.ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        return value?.hostID == hostID && value?.pairingCode == pairingCode ? value : nil
    }
    func save(_ pending: RemoteDesktopClientCore.ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }; value = pending; return true
    }
    func remove(hostID: String) {
        lock.lock(); defer { lock.unlock() }; if value?.hostID == hostID { value = nil }
    }
}

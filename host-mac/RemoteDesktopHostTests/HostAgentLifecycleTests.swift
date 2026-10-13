import XCTest
@testable import RemoteDesktopHost

@MainActor
final class HostAgentLifecycleTests: XCTestCase {
    func testLocalTakeoverRetainsPendingAgentApprovalAndResurfacesSameGate() async throws {
        let fixture = AdapterFixture(replies: [[
            .click(target: .element(id: 1), button: nil, count: nil),
            .done(answer: "Completed")
        ]])
        let channel = LifecycleChannel()
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostAgentLifecycle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }

        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            executor: ComputerUseCapabilityExecutor(
                agentAdapter: AgentCapabilityAdapter(executor: fixture.executor)),
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            allowsExternalServices: false)
        defer { _ = manager.stop() }

        let prompt = lifecycleEnvelope(id: "agent-local-takeover", kind: .prompt,
                                       body: "Click Submit once")
        manager.authorizePeer(senderID: prompt.senderID)
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { await channel.sentMessages().contains { $0.kind == .approvalRequest } }

        let initialMessages = await channel.sentMessages()
        let firstEnvelope = try XCTUnwrap(initialMessages.first { $0.kind == .approvalRequest })
        let firstApproval = try ComputerUseApprovalRequest.decodeBody(firstEnvelope.body)
        let rootLoop = try XCTUnwrap(fixture.executor.activeLoop)
        let gateID = try XCTUnwrap(UUID(uuidString: firstApproval.requestID))
        XCTAssertEqual(firstApproval.taskID, prompt.id)
        XCTAssertEqual(rootLoop.pendingStep?.approval.id, gateID)
        XCTAssertEqual(fixture.environments.first?.executed.count, 0)

        let workingControls = try XCTUnwrap(manager.localTaskControls)
        XCTAssertEqual(workingControls.phase, .awaitingApproval)
        manager.requestLocalTaskControl(.takeControl, displayed: workingControls)
        await waitUntil { manager.activity == .paused }

        XCTAssertEqual(manager.localTaskControls?.phase, .paused)
        XCTAssertEqual(manager.hasRetainedAgentTask, true)
        XCTAssertEqual(fixture.executor.activeTaskID, prompt.id)
        XCTAssertTrue(fixture.executor.activeLoop === rootLoop)
        XCTAssertFalse(rootLoop.didFinish)
        XCTAssertEqual(rootLoop.pendingStep?.approval.id, gateID)
        XCTAssertTrue(fixture.environments[0].executed.isEmpty)

        // The old card carries the pre-takeover revision and host epoch.
        // It must not release the effect while local ownership is paused.
        let staleResponse = ComputerUseApprovalResponse(
            requestID: firstApproval.requestID,
            approved: true,
            taskID: firstApproval.taskID,
            appliedControlRevision: firstApproval.appliedControlRevision,
            hostControlEpoch: firstApproval.hostControlEpoch)
        XCTAssertTrue(manager.handle(
            lifecycleEnvelope(id: "stale-agent-approval", kind: .approvalResponse,
                              body: try staleResponse.encodedBody()),
            channel: channel))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(manager.activity, .paused)
        XCTAssertTrue(fixture.environments[0].executed.isEmpty)

        let pausedControls = try XCTUnwrap(manager.localTaskControls)
        XCTAssertTrue(pausedControls.canResume)
        manager.requestLocalTaskControl(.resume, displayed: pausedControls)
        await waitUntil { await channel.sentMessages().filter { $0.kind == .approvalRequest }.count >= 2 }
        XCTAssertTrue({ if case .awaitingApproval = manager.activity { return true }; return false }())
        let approvals = await channel.sentMessages().filter { $0.kind == .approvalRequest }
        XCTAssertGreaterThanOrEqual(approvals.count, 2)
        let resumedApproval = try ComputerUseApprovalRequest.decodeBody(approvals.last!.body)
        XCTAssertEqual(resumedApproval.requestID, firstApproval.requestID)
        XCTAssertEqual(resumedApproval.taskID, firstApproval.taskID)
        XCTAssertNotEqual(resumedApproval.hostControlEpoch, firstApproval.hostControlEpoch)
        XCTAssertEqual(fixture.executor.activeLoop === rootLoop, true)
        XCTAssertFalse(rootLoop.didFinish)
        XCTAssertTrue(fixture.environments[0].executed.isEmpty)

        let approval = ComputerUseApprovalResponse(
            requestID: resumedApproval.requestID,
            approved: true,
            taskID: resumedApproval.taskID,
            appliedControlRevision: resumedApproval.appliedControlRevision,
            hostControlEpoch: resumedApproval.hostControlEpoch)
        XCTAssertTrue(manager.handle(
            lifecycleEnvelope(id: "current-agent-approval", kind: .approvalResponse,
                              body: try approval.encodedBody()),
            channel: channel))
        await waitUntil { manager.activity == .idle && fixture.executor.activeLoop?.didFinish == true }

        XCTAssertEqual(fixture.environments[0].executed.count, 1)
        XCTAssertEqual(fixture.policies[0].proposalCount, 2)
        XCTAssertEqual(fixture.executor.activeTaskID, prompt.id)
        XCTAssertTrue(fixture.executor.activeLoop === rootLoop)
        await waitUntil {
            await channel.sentMessages().contains { envelope in
                guard envelope.kind == .assistant,
                      let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) else { return false }
                return update.taskID == prompt.id && update.text == "Completed"
            }
        }
        let finalMessages = await channel.sentMessages()
        let terminalEnvelope = try XCTUnwrap(finalMessages.first { envelope in
            guard envelope.kind == .assistant,
                  let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) else { return false }
            return update.taskID == prompt.id
        })
        let terminal = try ComputerUseTaskUpdate.decodeBody(terminalEnvelope.body)
        XCTAssertEqual(terminal.taskID, prompt.id)
        XCTAssertEqual(terminal.text, "Completed")
        XCTAssertEqual(terminal.outcome, .taskCompleted)
        await manager.shutdown()
    }

    private func waitUntil(
        iterations: Int = 300,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the host Agent lifecycle")
    }
}

private actor LifecycleChannel: HostComputerUseChannel {
    private var messages: [ComputerUseEnvelope] = []

    func sentMessages() -> [ComputerUseEnvelope] { messages }

    func send(kind: ComputerUseEnvelope.Kind, body: String, to explicitTargetID: String?,
              sessionID explicitSessionID: String?, messageID explicitMessageID: String?) async throws
        -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: "HOST-ID",
            targetID: explicitTargetID ?? "IOS-PEER",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "SESSION-1",
            kind: kind,
            body: body)
        messages.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
    func stopPolling() async {}
}

private func lifecycleEnvelope(id: String, kind: ComputerUseEnvelope.Kind,
                               body: String = "") -> ComputerUseEnvelope {
    ComputerUseEnvelope(id: id, senderID: "IOS-PEER", targetID: "HOST-ID",
        pairingCode: "123456", sessionID: "SESSION-1", kind: kind, body: body)
}

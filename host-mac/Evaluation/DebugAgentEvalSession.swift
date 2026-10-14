#if DEBUG
import AppKit
import Foundation

@MainActor
final class DebugAgentEvalSession {
    private let request: AgentEvalRequest
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let hostID = UUID().uuidString
    private let senderID = UUID().uuidString
    private let sessionID = UUID().uuidString
    private let pairingCode = UUID().uuidString
    private let runStore: AgentEvalRunStore
    private let credential: LocalComputerUseCredential
    private let bootstrapStore: AgentEvalBootstrapStore
    private let channel: LocalHostComputerUseChannel
    private let manager: HostComputerUseManager
    private let broker: DebugAgentEvalBroker
    private var pendingAcknowledgements: [String] = []

    init(request: AgentEvalRequest) throws {
        self.request = request
        guard let evalRoot = ProcessInfo.processInfo.environment["REMOTE_DESKTOP_EVAL_ROOT"] else {
            throw AgentEvalWireError.bootstrapFailure
        }
        runStore = try AgentEvalRunStore(taskID: request.taskID, rootPath: evalRoot)
        credential = try LocalComputerUseCredential.generate()
        bootstrapStore = try AgentEvalBootstrapStore()
        channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        manager = HostComputerUseManager(injector: InputInjector(),
            allowsExternalServices: true, allowsAutomaticSetup: false,
            agentConfiguration: request.hostConfiguration(storageDirectory: runStore.directory))
        broker = DebugAgentEvalBroker(credential: credential, hostID: hostID,
            channel: channel,
            authorize: { [weak manager] peerID in manager?.authorizeLocalPeer(senderID: peerID) ?? false },
            revoke: { [weak manager] peerID in manager?.revokeLocalPeerAuthorization(senderID: peerID) })
    }

    func run() async throws -> AgentEvalResponse {
        defer {
            broker.stop()
            bootstrapStore.remove()
        }
        do {
            guard await waitForModel() else { throw AgentEvalWireError.modelUnavailable }
            try await openSetupDocumentIfNeeded()
            let port = try await broker.start()
            let bootstrap = AgentEvalBootstrap(hostID: hostID, senderID: senderID,
                sessionID: sessionID, pairingCode: pairingCode, port: port,
                accessKey: credential.accessKey)
            try bootstrapStore.write(bootstrap)
            let loaded = try bootstrapStore.read()
            let clientCredential = try LocalComputerUseCredential(accessKey: loaded.accessKey)
            let endpoint = LocalComputerUseEndpoint(host: "127.0.0.1", port: loaded.port)

            manager.start(pairingCode: pairingCode, additionalChannels: [channel],
                includeDefaultChannel: false, forceMultiplex: false)
            _ = try await exchange(bootstrap: loaded, credential: clientCredential,
                endpoint: endpoint, envelopes: [])

            let prompt = try ComputerUsePromptRequest(prompt: request.prompt,
                supportsApprovedActionEvidence: true).encodedBody()
            let envelope = makeEnvelope(kind: .prompt, body: prompt)
            _ = try await exchange(bootstrap: loaded, credential: clientCredential,
                endpoint: endpoint, envelopes: [envelope])
            let result = try await collectResult(bootstrap: loaded, credential: clientCredential,
                endpoint: endpoint)
            await manager.shutdown()
            return result
        } catch {
            await manager.shutdown()
            throw error
        }
    }

    func stop() async {
        await manager.shutdown()
        broker.stop()
        bootstrapStore.remove()
    }

    private func openSetupDocumentIfNeeded() async throws {
        guard let document = request.setupDocument, let appName = request.start.app,
              let task = ProcessInfo.processInfo.environment["EVAL_TASK_ID"],
              let token = ProcessInfo.processInfo.environment["EVAL_RUN_TOKEN"],
              AgentEvalSetupDocument.authorized(path: document.path, taskID: task, token: token) != nil,
              SuiteCleanStart.ownsNativeScratchDocument(url: document.absoluteString),
              let app = try? AgentAppRegistry().resolve(appName) else {
            if request.setupDocument != nil { throw AgentEvalWireError.invalidRequest }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([document], withApplicationAt: app.url,
                configuration: NSWorkspace.OpenConfiguration()) { applications, error in
                if let error { continuation.resume(throwing: error); return }
                guard applications?.bundleIdentifier == app.bundleID else {
                    continuation.resume(throwing: AgentEvalWireError.bootstrapFailure)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func waitForModel() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .ready = manager.modelState { return true }
            if case .error = manager.modelState { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    private func collectResult(bootstrap: AgentEvalBootstrap,
                               credential: LocalComputerUseCredential,
                               endpoint: LocalComputerUseEndpoint) async throws -> AgentEvalResponse {
        let deadline = startedAt + 15 * 60
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let response = try await exchange(bootstrap: bootstrap, credential: credential,
                endpoint: endpoint, envelopes: [], acknowledgements: pendingAcknowledgements)
            pendingAcknowledgements.removeAll()
            for envelope in response.envelopes where envelope.targetID == senderID {
                pendingAcknowledgements.append(envelope.id)
                if envelope.kind == .approvalRequest,
                   let approval = try? ComputerUseApprovalRequest.decodeBody(envelope.body),
                   approval.taskID == request.taskID {
                    if try await approveFixtureRequest(approval, bootstrap: bootstrap,
                        credential: credential, endpoint: endpoint) { continue }
                    return makeResult(outcome: "pending_approval", answer: approval.message)
                }
                guard envelope.kind == .assistant || envelope.kind == .status,
                      let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body),
                      update.taskID == request.taskID else { continue }
                if let result = terminalResult(update) { return makeResult(outcome: result.0, answer: result.1) }
                if envelope.kind == .status,
                   update.outcome == .userInterventionRequired {
                    return makeResult(outcome: "handoff", answer: update.text)
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        try await sendCancel(bootstrap: bootstrap, credential: credential, endpoint: endpoint)
        return makeResult(outcome: "timeout", answer: "The host task exceeded its 15-minute deadline and was cancelled.")
    }

    private func approveFixtureRequest(_ approval: ComputerUseApprovalRequest,
                                       bootstrap: AgentEvalBootstrap,
                                       credential: LocalComputerUseCredential,
                                       endpoint: LocalComputerUseEndpoint) async throws -> Bool {
        guard request.allowsFixtureCommit || request.allowsFixtureInteraction || request.allowsStartInteraction,
              let pending = manager.debugPendingAgentApproval(taskID: request.taskID,
                requestID: approval.requestID),
              isAuthorizedApproval(pending, approval: approval) else { return false }
        let response = ComputerUseApprovalResponse(requestID: approval.requestID, approved: true,
            taskID: approval.taskID, appliedControlRevision: approval.appliedControlRevision,
            hostControlEpoch: approval.hostControlEpoch)
        let envelope = makeEnvelope(kind: .approvalResponse, body: try response.encodedBody())
        _ = try await exchange(bootstrap: bootstrap, credential: credential,
            endpoint: endpoint, envelopes: [envelope], acknowledgements: pendingAcknowledgements)
        pendingAcknowledgements.removeAll()
        return true
    }

    private func isAuthorizedApproval(_ pending: AgentLoop.PendingStep,
                                      approval: ComputerUseApprovalRequest) -> Bool {
        guard pending.approval.taskID == request.taskID,
              pending.approval.id.uuidString == approval.requestID,
              pending.approval.action == pending.resolved.action,
              request.start.url != nil || request.start.app != nil else { return false }
        let surface = pending.resolved.frame.observation.surface
        let currentURL: String?
        let currentApp: String?
        switch surface {
        case .web(let url, _): currentURL = url; currentApp = nil
        case .app(let bundleID, _): currentURL = nil; currentApp = bundleID
        }
        let expectedApp = request.start.app.flatMap { try? AgentAppRegistry().resolve($0).bundleID }
        return AgentEvalApprovalPolicy.permits(.init(
            taskID: pending.approval.taskID,
            requestID: pending.approval.id.uuidString,
            fingerprint: pending.approval.fingerprint,
            approvalScope: pending.approval.scopeIdentity,
            resolvedScope: pending.resolved.frame.scope.identity,
            riskTier: pending.approval.riskTier.rawValue,
            action: pending.resolved.action,
            currentURL: currentURL,
            expectedURL: request.start.url,
            currentApp: currentApp,
            expectedApp: expectedApp,
            targetRoles: pending.resolved.targets.map(\.role),
            hasSensitiveTarget: hasSensitiveTarget(pending),
            hasSyntheticFileRoot: request.hasSyntheticFileRoot), request: request)
    }

    private func hasSensitiveTarget(_ pending: AgentLoop.PendingStep) -> Bool {
        if let focus = pending.resolved.frame.observation.focus,
           AgentCredentialRule.isSensitive(role: focus.role, name: focus.name, state: []) { return true }
        return pending.resolved.targets.contains {
            AgentCredentialRule.isSensitive(role: $0.role, name: $0.name, state: $0.state)
        }
    }

    private func sendCancel(bootstrap: AgentEvalBootstrap,
                            credential: LocalComputerUseCredential,
                            endpoint: LocalComputerUseEndpoint) async throws {
        let control = ComputerUseControlRequest(taskID: request.taskID, revision: 1)
        let envelope = makeEnvelope(kind: .cancel, body: try control.encodedBody())
        _ = try await exchange(bootstrap: bootstrap, credential: credential,
            endpoint: endpoint, envelopes: [envelope], acknowledgements: pendingAcknowledgements)
        pendingAcknowledgements.removeAll()
    }

    private func exchange(bootstrap: AgentEvalBootstrap, credential: LocalComputerUseCredential,
                          endpoint: LocalComputerUseEndpoint, envelopes: [ComputerUseEnvelope],
                          acknowledgements: [String] = []) async throws -> LocalComputerUseRPCResponse {
        let request = LocalComputerUseRPCRequest(senderID: bootstrap.senderID,
            targetID: bootstrap.hostID, sessionID: bootstrap.sessionID,
            envelopes: envelopes, acknowledgedEnvelopeIDs: acknowledgements)
        return try await LocalComputerUseRPCTransport.call(endpoint: endpoint,
            credential: credential, request: request)
    }

    private func makeEnvelope(kind: ComputerUseEnvelope.Kind, body: String) -> ComputerUseEnvelope {
        ComputerUseEnvelope(id: kind == .prompt ? request.taskID : UUID().uuidString,
            senderID: senderID, targetID: hostID, pairingCode: pairingCode,
            sessionID: sessionID, kind: kind, body: body)
    }

    private func terminalResult(_ update: ComputerUseTaskUpdate) -> (String, String)? {
        guard let outcome = update.outcome else { return nil }
        switch outcome {
        case .taskCompleted: return ("completed", update.text)
        case .unableToComplete: return ("failed", update.text)
        case .userInterventionRequired:
            return (update.clarification == nil ? "handoff" : "ask_user", update.text)
        }
    }

    private func makeResult(outcome: String, answer: String) -> AgentEvalResponse {
        let requestedCropMode = ["ui-tars15-7b", "gui-owl15-4b"].contains(request.policy)
            ? "full-display" : "frontmost-window"
        let metadataURL = runStore.directory.appendingPathComponent("pixel-metadata.json")
        let cropMode = AgentEvalPixelMetadata.actualCropMode(from: try? Data(contentsOf: metadataURL))
        return AgentEvalResponse(taskID: request.taskID, outcome: outcome, answer: answer,
            episodePath: runStore.episodePath,
            wallSeconds: max(0, ProcessInfo.processInfo.systemUptime - startedAt),
            policy: request.policy, cropMode: cropMode, requestedCropMode: requestedCropMode)
    }

}
#endif

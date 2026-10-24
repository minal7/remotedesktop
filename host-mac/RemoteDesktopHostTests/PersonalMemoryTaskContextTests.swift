import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

@MainActor
final class PersonalMemoryTaskContextTests: XCTestCase {
    func testManagerLeaseBoxRevokesSynchronousWriterAuthorityBeforeStaging() {
        let box = TaskMemoryContextLeaseAuthorizationBox()
        let slot = TaskMemoryContextSlot(leaseAuthorizationBox: box)
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(),
            sessionID: "lease-box-session", taskID: "lease-box-task",
            authorizationGeneration: 4, taskAuthority: .active)

        slot.bindLease(lease)
        XCTAssertTrue(box.isCurrent(lease))
        XCTAssertFalse(box.isCurrent(LocalMemoryHostLease(peerID: lease.peerID,
            sessionID: lease.sessionID, taskID: lease.taskID,
            authorizationGeneration: 5, taskAuthority: .active)))

        slot.clear()
        XCTAssertFalse(box.isCurrent(lease), "Clearing an unstaged task must revoke writer callbacks too.")
        XCTAssertTrue(slot.contains(taskID: "lease-box-task"),
            "A task whose retrieval began before revocation must not silently continue without context.")
    }

    func testMissingFirstStoreRunsOrdinaryTaskWithoutMemoryContext() async throws {
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        let provider = MissingStoreContextProvider(), observed = ContextObservedPolicy()
        let slot = TaskMemoryContextSlot()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("missing-first-store", peer: peer, session: session), channel: channel))
        await waitUntil { observed.observations.count == 1 && manager.activity == .idle }
        XCTAssertFalse(observed.observations[0].task.contains("<saved-memory-reference-data>"))
        let prepares = await provider.prepareCalls
        XCTAssertEqual(prepares, 0)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    func testAcceptedManagerTaskBuildsRealContextForSameAgentPolicyOnly() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased()
        let session = "memory-context-session"
        let owner = String(repeating: "c", count: 64)
        let ownerContext = OwnerMemoryContext(ownerID: owner, sessionID: session, taskID: "memory-task")
        try store.service.writer.remember(kind: .fact, text: "Harbor City is my fictional saved preference.",
            commandID: UUID().uuidString.lowercased(), context: ownerContext)
        let builder = MemoryContextBuilder(writer: store.service.writer,
            embedding: ContextEmbedding(), tokenCounter: ContextTokenCounter())
        let leaseAuthority = TaskMemoryContextLeaseAuthorizationBox()
        let provider = BuilderContextProvider(binding: store.binding, builder: builder,
            ownerID: owner, sessionID: session, leaseAuthority: leaseAuthority)
        let slot = TaskMemoryContextSlot(leaseAuthorizationBox: leaseAuthority)
        let observed = ContextObservedPolicy()
        let agentExecutor = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agentExecutor))
        let channel = ContextHostChannel(hostID: UUID().uuidString)
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContext-\(UUID())/ledger.json")
        let manager = HostComputerUseManager(injector: InputInjector(eventPoster: { _ in },
            physicalInputState: { .released }, displayState: { _ in nil }), executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL), allowsExternalServices: false,
            allowsAutomaticSetup: false, taskMemoryContextProvider: provider, taskMemoryContextSlot: slot)
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        let request = ComputerUsePromptRequest(prompt: "Use Harbor City", memoryPolicy: .init())
        XCTAssertTrue(manager.handle(.init(id: "memory-task", senderID: peer, targetID: UUID().uuidString,
            pairingCode: "123456", sessionID: session, kind: .prompt,
            body: try request.encodedBody()), channel: channel))
        await waitUntil { !observed.observations.isEmpty && manager.activity == .idle }
        XCTAssertTrue(observed.observations.first?.task.contains("Harbor City") == true)
        XCTAssertEqual(observed.observations.first?.task.components(separatedBy: "<saved-memory-reference-data>").count, 2)
        XCTAssertEqual(agentExecutor.activeLoop?.taskText, "Use Harbor City")
        XCTAssertEqual(agentExecutor.activePrompt, "Use Harbor City")
        XCTAssertEqual(observed.recordedTask, "Use Harbor City", "The task journal must retain the unmodified observation.")
        let prepareCalls = await provider.calls
        XCTAssertEqual(prepareCalls, 1)
        let wasAuthorizedAtCapture = await provider.leaseWasAuthorizedAtCapture
        XCTAssertTrue(wasAuthorizedAtCapture, "Manager must bind the accepted lease before storage capture.")
        await manager.shutdown()
        XCTAssertFalse(leaseAuthority.isCurrent(LocalMemoryHostLease(peerID: peer,
            sessionID: session, taskID: "memory-task", authorizationGeneration: 1,
            taskAuthority: .active)))
    }
    func testPolicyReceivesContextCopyWithoutChangingSourceObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContext-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try MemoryStoreFactory.preparePrivateRoot(root)
        let namespace = KeychainNamespace.testing(UUID().uuidString)
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true, root: root,
            client: ContextTestKeychain(), namespace: namespace))
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "session",
            taskID: "task", authorizationGeneration: 1, taskAuthority: .active)
        let slot = TaskMemoryContextSlot()
        slot.stage("Fictional preference: Harbor City", taskID: "task", lease: lease, binding: binding) { true }
        let base = ContextRecordingPolicy()
        let policy = TaskMemoryContextPolicy.applying(taskID: "task", slot: slot, base: base)
        let observation = AgentObservation(task: "Use saved preference", surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic", elements: [], focus: nil, history: [], budget: AgentStepBudget(step: 0, maxSteps: 1))
        _ = try await policy.propose(observation)
        XCTAssertEqual(observation.task, "Use saved preference")
        XCTAssertEqual(base.seen?.task, "Use saved preference\n\n<saved-memory-reference-data>\nFictional preference: Harbor City\n</saved-memory-reference-data>")
    }
    func testRevokedContextCannotBeUsedByPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContext-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try MemoryStoreFactory.preparePrivateRoot(root)
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true, root: root,
            client: ContextTestKeychain(), namespace: .testing(UUID().uuidString)))
        var valid = true
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "session",
            taskID: "task", authorizationGeneration: 1, taskAuthority: .active)
        let slot = TaskMemoryContextSlot()
        slot.stage("synthetic context", taskID: "task", lease: lease, binding: binding) { valid }
        let base = ContextRecordingPolicy()
        let policy = TaskMemoryContextPolicy.applying(taskID: "task", slot: slot, base: base)
        let observation = AgentObservation(task: "Original", surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic", elements: [], focus: nil, history: [], budget: AgentStepBudget(step: 0, maxSteps: 1))
        valid = false
        do {
            _ = try await policy.propose(observation)
            XCTFail("A revoked task context must fail closed")
        } catch is TaskMemoryContextFailure {}
        XCTAssertNil(base.seen, "The stale context must be rejected before a policy call")
    }
    func testPolicyResultIsDiscardedWhenContextIsRevokedDuringAwait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContext-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try MemoryStoreFactory.preparePrivateRoot(root)
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: ContextTestKeychain(), namespace: .testing(UUID().uuidString)))
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "session",
            taskID: "task", authorizationGeneration: 1, taskAuthority: .active)
        let slot = TaskMemoryContextSlot()
        slot.stage("synthetic context", taskID: "task", lease: lease, binding: binding) { true }
        let base = BlockingContextPolicy()
        let policy = TaskMemoryContextPolicy.applying(taskID: "task", slot: slot, base: base)
        let observation = AgentObservation(task: "Original", surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic", elements: [], focus: nil, history: [], budget: AgentStepBudget(step: 0, maxSteps: 1))
        let proposal = Task { try await policy.propose(observation) }
        let entered = await base.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { slot.clear(); return }
        slot.clear()
        await base.release()
        do {
            _ = try await proposal.value
            XCTFail("A policy result from a revoked task context must not escape")
        } catch is TaskMemoryContextFailure {}
    }
    func testIncognitoAndNoMemorySkipAllContextProviderCalls() async throws {
        for policy in [ComputerUseTaskMemoryPolicy(noMemory: true),
                       ComputerUseTaskMemoryPolicy(incognito: true)] {
            let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
            let provider = CountingContextProvider(), slot = TaskMemoryContextSlot()
            let observed = ContextObservedPolicy()
            let agent = AgentTaskExecutor { taskID, prompt in
                try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
            }
            let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
            let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
                executor: executor, provider: provider, slot: nil)
            XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
            XCTAssertTrue(manager.handle(try prompt("privacy-gated", peer: peer, session: session,
                policy: policy), channel: channel))
            await waitUntil { manager.activity == .idle }
            XCTAssertEqual(observed.observations.count, 1)
            XCTAssertFalse(observed.observations.first?.task.contains("<saved-memory-reference-data>") ?? true)
            let counts = await provider.counts
            XCTAssertEqual(counts.capture, 0)
            XCTAssertEqual(counts.prepare, 0)
            await manager.shutdown()
            try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        }
    }
    func testPauseLearningStillAllowsTaskContextReads() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        try store.service.writer.remember(kind: .fact, text: "Harbor City preference",
            commandID: UUID().uuidString.lowercased(), context: OwnerMemoryContext(ownerID: store.owner,
                sessionID: "pause-learning-session", taskID: "pause-learning-task"))
        let session = "pause-learning-session"
        let provider = BuilderContextProvider(binding: store.binding,
            builder: MemoryContextBuilder(writer: store.service.writer, embedding: ContextEmbedding(),
                tokenCounter: ContextTokenCounter()), ownerID: store.owner, sessionID: session)
        let slot = TaskMemoryContextSlot(), observed = ContextObservedPolicy()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let peer = UUID().uuidString.lowercased()
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("pause-learning-task", peer: peer, session: session,
            policy: .init(pauseLearning: true)), channel: channel))
        await waitUntil { observed.observations.count == 1 && manager.activity == .idle }
        XCTAssertTrue(observed.observations[0].task.contains("Harbor City preference"))
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }
    func testConfiguredProviderWithoutSlotFailsClosedBeforeAgentPolicy() async throws {
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        let provider = CountingContextProvider(), observed = ContextObservedPolicy()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: nil)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: nil)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("missing-slot", peer: peer, session: session), channel: channel))
        await waitUntil { manager.activity == .idle }
        XCTAssertTrue(observed.observations.isEmpty)
        let counts = await provider.counts
        XCTAssertEqual(counts.capture, 0)
        XCTAssertEqual(counts.prepare, 0)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }
    func testRevocationDuringCancellationIgnoringCaptureCannotStageLateContext() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        let provider = BlockingCaptureProvider(binding: store.binding), slot = TaskMemoryContextSlot()
        let observed = ContextObservedPolicy()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("blocked-capture", peer: peer, session: session), channel: channel))
        let entered = await provider.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { await manager.shutdown(); return }
        manager.revokeLocalPeerAuthorization(senderID: peer)
        await provider.release()
        await manager.shutdown()
        XCTAssertTrue(observed.observations.isEmpty)
        let prepareCalls = await provider.prepareCallCount
        XCTAssertEqual(prepareCalls, 0)
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    func testStopJoinsCancellationIgnoringContextPreparation() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        let provider = BlockingPrepareProvider(binding: store.binding), slot = TaskMemoryContextSlot()
        let observed = ContextObservedPolicy()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("stop-while-preparing", peer: peer, session: session), channel: channel))
        let entered = await provider.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { await manager.shutdown(); return }

        _ = manager.stop()
        let joined = ContextJoinProbe()
        let shutdown = Task { @MainActor in
            await manager.shutdown()
            await joined.markComplete()
        }
        try await Task.sleep(for: .milliseconds(50))
        let finishedBeforeRelease = await joined.isComplete
        XCTAssertFalse(finishedBeforeRelease, "Shutdown must join cancellation-ignoring preparation")
        await provider.release()
        await shutdown.value
        XCTAssertTrue(observed.observations.isEmpty, "Stopped preparation must never reach policy")
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }
    func testExplicitPauseResumePreparesFreshTaskContext() async throws {
        let store = try ContextStoreFixture(); defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        try store.service.writer.remember(kind: .fact, text: "Harbor City resume fixture",
            commandID: UUID().uuidString.lowercased(), context: OwnerMemoryContext(ownerID: store.owner,
                sessionID: session, taskID: "resume-root"))
        let provider = BuilderContextProvider(binding: store.binding,
            builder: MemoryContextBuilder(writer: store.service.writer, embedding: ContextEmbedding(),
                tokenCounter: ContextTokenCounter()), ownerID: store.owner, sessionID: session)
        let slot = TaskMemoryContextSlot(), observed = ContextObservedPolicy(blocksFirstProposal: true)
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("resume-root", peer: peer, session: session), channel: channel))
        let entered = await observed.waitUntilBlocked()
        guard entered, let working = manager.localTaskControls else {
            await observed.releaseBlock(); await manager.shutdown()
            try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
            XCTFail("Task should reach its first policy proposal")
            return
        }
        manager.requestLocalTaskControl(.takeControl, displayed: working)
        guard manager.localTaskControls?.phase == .paused else {
            await observed.releaseBlock(); await manager.shutdown()
            try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
            XCTFail("Task should pause before resuming"); return
        }
        await observed.releaseBlock()
        guard let paused = manager.localTaskControls, paused.phase == .paused, paused.canResume else {
            await manager.shutdown(); try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
            XCTFail("Task should expose a current resumable control after pause unwinds"); return
        }
        manager.requestLocalTaskControl(.resume, displayed: paused)
        if case .paused = manager.activity { XCTFail("Current resumable control should start the continuation") }
        await waitUntil { observed.observations.count == 2 && manager.activity == .idle }
        let calls = await provider.calls
        let finalControls = manager.localTaskControls, loop = agent.activeLoop
        let updates = await channel.diagnosticSummary()
        let diagnostic = "activity=\(manager.activity), controls=\(String(describing: finalControls?.phase))/\(finalControls?.canResume ?? false), loopFinished=\(loop?.didFinish ?? false), terminal=\(String(describing: loop?.terminalResult)), pauseRequested=\(loop?.pauseRequested ?? false), observations=\(observed.observations.count), providerCalls=\(calls), updates=\(updates)"
        XCTAssertEqual(observed.observations.count, 2, diagnostic)
        XCTAssertEqual(calls, 2, "Resume must rebuild context after the prior slot was cleared. \(diagnostic)")
        XCTAssertTrue(observed.observations.allSatisfy { $0.task.contains("Harbor City resume fixture") })
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    func testBindingChangeAfterPreparationFailsBeforePolicy() async throws {
        let firstRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TaskBindingA-\(UUID())", isDirectory: true)
        let nextRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TaskBindingB-\(UUID())", isDirectory: true)
        let client = ContextTestKeychain()
        try MemoryStoreFactory.preparePrivateRoot(firstRoot)
        try MemoryStoreFactory.preparePrivateRoot(nextRoot)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: nextRoot)
        }
        let first = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true, root: firstRoot,
            client: client, namespace: .testing(UUID().uuidString)))
        let next = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true, root: nextRoot,
            client: client, namespace: .testing(UUID().uuidString)))
        let provider = RotatingBindingProvider(first: first, next: next)
        let slot = TaskMemoryContextSlot(), observed = ContextObservedPolicy()
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("binding-rotated", peer: peer, session: session), channel: channel))
        let entered = await provider.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { await manager.shutdown(); return }
        await provider.release()
        await waitUntil { manager.activity == .idle }
        XCTAssertTrue(observed.observations.isEmpty)
        let preparationCalls = await provider.preparationCalls
        XCTAssertEqual(preparationCalls, 1)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    func testMemoryContextSurvivesAskUserContinuationWithoutRepreparation() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        try store.service.writer.remember(kind: .fact, text: "Harbor City is the fictional saved preference.",
            commandID: UUID().uuidString.lowercased(), context: OwnerMemoryContext(ownerID: store.owner,
                sessionID: session, taskID: "question-root"))
        let provider = BuilderContextProvider(binding: store.binding,
            builder: MemoryContextBuilder(writer: store.service.writer, embedding: ContextEmbedding(),
                tokenCounter: ContextTokenCounter()), ownerID: store.owner, sessionID: session)
        let slot = TaskMemoryContextSlot()
        let observed = ContextObservedPolicy(actions: [
            .askUser(question: "Which city?", choices: nil),
            .askUser(question: "Which region?", choices: nil), .done(answer: "Completed")
        ])
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot)
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        XCTAssertTrue(manager.handle(try prompt("question-root", peer: peer, session: session), channel: channel))
        let reference = try await channel.waitForClarification(taskID: "question-root")
        XCTAssertTrue(manager.handle(ComputerUseEnvelope(id: "question-answer", senderID: peer,
            targetID: channel.hostID, pairingCode: "123456", sessionID: session, kind: .prompt,
            body: try ComputerUsePromptRequest.answering(reference, text: "Harbor City",
                memoryPolicy: .init(incognito: true)).encodedBody()), channel: channel))
        let secondReference = try await channel.waitForClarification(taskID: "question-answer")
        XCTAssertTrue(manager.handle(ComputerUseEnvelope(id: "question-answer-2", senderID: peer,
            targetID: channel.hostID, pairingCode: "123456", sessionID: session, kind: .prompt,
            body: try ComputerUsePromptRequest.answering(secondReference, text: "Harbor City",
                memoryPolicy: .init(incognito: true)).encodedBody()), channel: channel))
        await waitUntil { manager.activity == .idle }
        XCTAssertEqual(observed.observations.count, 3)
        XCTAssertTrue(observed.observations.allSatisfy {
            $0.task.contains("<saved-memory-reference-data>") && $0.task.contains("Harbor City")
        })
        let prepareCalls = await provider.calls
        XCTAssertEqual(prepareCalls, 1)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    func testMemoryContextSurvivesAgentApprovalContinuation() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let peer = UUID().uuidString.lowercased(), session = UUID().uuidString
        try store.service.writer.remember(kind: .fact, text: "Harbor City is the fictional saved preference.",
            commandID: UUID().uuidString.lowercased(), context: OwnerMemoryContext(ownerID: store.owner,
                sessionID: session, taskID: "approval-root"))
        let provider = BuilderContextProvider(binding: store.binding,
            builder: MemoryContextBuilder(writer: store.service.writer, embedding: ContextEmbedding(),
                tokenCounter: ContextTokenCounter()), ownerID: store.owner, sessionID: session)
        let slot = TaskMemoryContextSlot()
        let observed = ContextObservedPolicy(actions: [
            .click(target: .element(id: 1), button: nil, count: nil), .done(answer: "Completed")
        ])
        let agent = AgentTaskExecutor { taskID, prompt in
            try self.makeLoop(taskID: taskID, prompt: prompt, policy: observed, slot: slot,
                allowPolicy: ContextApprovalPolicy())
        }
        let executor = ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: agent))
        let (manager, channel, ledgerURL) = makeManager(peer: peer, session: session,
            executor: executor, provider: provider, slot: slot,
            approvalTargetProvider: { _ in ComputerUseApprovalTargetSnapshot(context: "synthetic",
                applicationID: "test.fixture", accessibilityIdentity: "target-1") })
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peer))
        let targetID = UUID().uuidString
        XCTAssertTrue(manager.handle(try prompt("approval-root", peer: peer, session: session,
            targetID: targetID), channel: channel))
        let approval = try await channel.waitForApproval(taskID: "approval-root")
        let response = ComputerUseApprovalResponse(requestID: approval.requestID, approved: true,
            taskID: approval.taskID, appliedControlRevision: approval.appliedControlRevision,
            hostControlEpoch: approval.hostControlEpoch)
        XCTAssertTrue(manager.handle(ComputerUseEnvelope(senderID: peer, targetID: targetID,
            pairingCode: "123456", sessionID: session, kind: .approvalResponse,
            body: try response.encodedBody()), channel: channel))
        await waitUntil { manager.activity == .idle }
        XCTAssertEqual(observed.observations.count, 2)
        XCTAssertTrue(observed.observations.allSatisfy { $0.task.contains("<saved-memory-reference-data>") })
        let prepareCalls = await provider.calls
        XCTAssertEqual(prepareCalls, 1)
        await manager.shutdown()
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    private func makeLoop(taskID: String, prompt: String, policy: ContextObservedPolicy,
                          slot: TaskMemoryContextSlot?, allowPolicy: ContextAllowPolicy? = nil) throws -> AgentLoop {
        let selectedAllowPolicy = allowPolicy ?? ContextAllowPolicy()
        return try AgentLoop(taskID: taskID, prompt: prompt,
            environment: ContextEnvironment(taskID: taskID),
            policy: TaskMemoryContextPolicy.applying(taskID: taskID, slot: slot, base: policy),
            gate: AgentActionGate(trustStore: ContextTrustStore(), allowPolicy: selectedAllowPolicy),
            recorder: ContextRecorder(policy: policy), journal: ContextJournal())
    }

    private func makeManager(peer: String, session: String, executor: any ComputerUseExecuting,
        provider: any PersonalMemoryTaskContextProviding, slot: TaskMemoryContextSlot?,
        approvalTargetProvider: ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil
    ) -> (HostComputerUseManager, ContextHostChannel, URL) {
        let channel = ContextHostChannel(hostID: UUID().uuidString)
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContext-\(UUID())/ledger.json")
        let manager = HostComputerUseManager(injector: InputInjector(eventPoster: { _ in },
            physicalInputState: { .released }, displayState: { _ in nil }), executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL), allowsExternalServices: false,
            allowsAutomaticSetup: false, taskMemoryContextProvider: provider,
            taskMemoryContextSlot: slot, approvalTargetProvider: approvalTargetProvider)
        return (manager, channel, ledgerURL)
    }

    private func prompt(_ id: String, peer: String, session: String,
                        policy: ComputerUseTaskMemoryPolicy = .init(), targetID: String? = nil) throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(id: id, senderID: peer, targetID: targetID ?? UUID().uuidString,
            pairingCode: "123456", sessionID: session, kind: .prompt,
            body: try ComputerUsePromptRequest(prompt: "Use the saved preference", memoryPolicy: policy).encodedBody())
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for synthetic task-context result")
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

actor MissingStoreContextProvider: PersonalMemoryTaskContextProviding {
    private(set) var prepareCalls = 0
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? { nil }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding,
                 prompt: String) async throws -> String? {
        prepareCalls += 1
        return nil
    }
}

actor BuilderContextProvider: PersonalMemoryTaskContextProviding {
    let binding: MemoryStoreBinding
    let builder: MemoryContextBuilder
    let ownerID: String
    let sessionID: String
    let leaseAuthority: TaskMemoryContextLeaseAuthorizationBox?
    private(set) var calls = 0
    private(set) var leaseWasAuthorizedAtCapture = false
    init(binding: MemoryStoreBinding, builder: MemoryContextBuilder, ownerID: String, sessionID: String,
         leaseAuthority: TaskMemoryContextLeaseAuthorizationBox? = nil) {
        self.binding = binding; self.builder = builder; self.ownerID = ownerID; self.sessionID = sessionID
        self.leaseAuthority = leaseAuthority
    }
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? {
        if let leaseAuthority { leaseWasAuthorizedAtCapture = leaseAuthority.isCurrent(lease) }
        return binding
    }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, prompt: String) async throws -> String? {
        calls += 1
        let result = try await builder.build(.init(context: OwnerMemoryContext(ownerID: ownerID,
            sessionID: sessionID, taskID: lease.taskID ?? ""), query: prompt, tokenBudget: 128))
        return result.serializedContext
    }
}

actor CountingContextProvider: PersonalMemoryTaskContextProviding {
    private(set) var captureCalls = 0
    private(set) var prepareCalls = 0
    var counts: (capture: Int, prepare: Int) { (captureCalls, prepareCalls) }
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? {
        captureCalls += 1
        return nil
    }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, prompt: String) async throws -> String? {
        prepareCalls += 1
        return "synthetic"
    }
}

actor BlockingCaptureProvider: PersonalMemoryTaskContextProviding {
    let binding: MemoryStoreBinding
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var prepareCallCount = 0
    init(binding: MemoryStoreBinding) { self.binding = binding }
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? {
        entered = true
        await withCheckedContinuation { releaseWaiter = $0 }
        return binding
    }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, prompt: String) async throws -> String? {
        prepareCallCount += 1
        return "late synthetic context"
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

actor BlockingPrepareProvider: PersonalMemoryTaskContextProviding {
    let binding: MemoryStoreBinding
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(binding: MemoryStoreBinding) { self.binding = binding }
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? { binding }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, prompt: String) async throws -> String? {
        entered = true
        await withCheckedContinuation { releaseWaiter = $0 }
        return "late synthetic context"
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

actor ContextJoinProbe {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

actor RotatingBindingProvider: PersonalMemoryTaskContextProviding {
    let first: MemoryStoreBinding
    let next: MemoryStoreBinding
    private var captures = 0
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var preparationCalls = 0
    init(first: MemoryStoreBinding, next: MemoryStoreBinding) { self.first = first; self.next = next }
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? {
        captures += 1
        return captures == 1 ? first : next
    }
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, prompt: String) async throws -> String? {
        preparationCalls += 1
        entered = true
        await withCheckedContinuation { releaseWaiter = $0 }
        return "synthetic context from old generation"
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

struct ContextEmbedding: LocalMemoryEmbeddingProvider {
    let identity = "test-local-embedding"
    let dimensions = 2
    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] { [1, 0] }
}
struct ContextTokenCounter: MemoryExactTokenCounter {
    func countTokens(in completeContext: String) async throws -> Int { completeContext.split(whereSeparator: \.isWhitespace).count }
}

final class ContextStoreFixture {
    let root: URL
    let service: PersonalMemoryService
    let binding: MemoryStoreBinding
    private let keychain: ContextTestKeychain
    let owner = String(repeating: "c", count: 64)
    func cleanup() { try? service.close(); try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    init() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("TaskContextStore-\(UUID())", isDirectory: true)
        let storeRoot = parent.appendingPathComponent("memory", isDirectory: true)
        root = storeRoot
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try MemoryStoreFactory.preparePrivateRoot(storeRoot)
        let keychain = ContextTestKeychain()
        self.keychain = keychain
        let namespace = KeychainNamespace.testing(UUID().uuidString)
        let ownerID = owner
        let opened = try XCTUnwrap(try MemoryStoreFactory.openForTesting(enabled: true, root: storeRoot,
            client: keychain, random: ContextKeyRandom(), namespace: namespace,
            authorize: { $0.ownerID == ownerID }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        service = opened
        binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: storeRoot, client: keychain, namespace: namespace))
    }
}

struct ContextKeyRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x38, count: count) }
}

@MainActor final class ContextObservedPolicy: AgentPolicy {
    let promptVersion = "task-context-test"
    private(set) var observations: [AgentObservation] = []
    var recordedTask: String?
    private var actions: [AgentAction]
    private var blockFirstProposal: Bool
    private var blockWaiter: CheckedContinuation<Void, Never>?
    init(actions: [AgentAction] = [.done(answer: "done")], blocksFirstProposal: Bool = false) {
        self.actions = actions; blockFirstProposal = blocksFirstProposal
    }
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        observations.append(observation)
        if blockFirstProposal {
            blockFirstProposal = false
            await withCheckedContinuation { blockWaiter = $0 }
        }
        let action = actions.isEmpty ? .done(answer: "done") : actions.removeFirst()
        return .init(rawOutput: "synthetic", action: action, rejectionReason: nil)
    }
    func waitUntilBlocked() async -> Bool {
        for _ in 0..<200 { if blockWaiter != nil { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return blockWaiter != nil
    }
    func releaseBlock() { blockWaiter?.resume(); blockWaiter = nil }
    func stop() async {}
}

@MainActor final class ContextRecorder: AgentRecording {
    private let policy: ContextObservedPolicy
    init(policy: ContextObservedPolicy) { self.policy = policy }
    func record(_ step: AgentEpisodeStep) throws { policy.recordedTask = step.observation.task }
    func finish(_ footer: AgentEpisodeFooter) throws {}
}

@MainActor final class ContextJournal: AgentEffectJournaling {
    func begin(step: Int, fingerprint: String) throws {}
    func verify(step: Int, fingerprint: String) throws {}
    func markUncertain(step: Int, fingerprint: String) throws {}
    func assertMayContinue() throws {}
}

@MainActor final class ContextTrustStore: AgentTrustStore {
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool { true }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws {}
}
@MainActor class ContextAllowPolicy: AgentAllowPolicy {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
}
@MainActor final class ContextApprovalPolicy: ContextAllowPolicy {
    override func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision {
        if case .click = action {
            return .approvalRequired("Synthetic approval", trustIdentity: nil)
        }
        return .allowed
    }
}

@MainActor final class ContextEnvironment: AgentEnvironment {
    let taskID: String
    init(taskID: String) { self.taskID = taskID }
    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        let observation = AgentObservation(task: context.task, surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic", elements: [], focus: nil, history: context.history, budget: context.budget)
        return AgentFrame(observation: observation, scope: AgentScope(taskID: taskID, kind: .web, identity: "fixture"))
    }
    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction { .init(action: action, frame: frame, targets: []) }
    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult { .init(status: .ok, result: "done") }
    func suspend() async {}
    func resume() async throws {}
    func stop() async {}
}

actor ContextHostChannel: HostComputerUseChannel {
    let hostID: String
    private var sent: [ComputerUseEnvelope] = []
    init(hostID: String) { self.hostID = hostID }
    func send(kind: ComputerUseEnvelope.Kind, body: String, to target: String?, sessionID: String?, messageID: String?) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(id: messageID ?? UUID().uuidString, senderID: hostID,
            targetID: target ?? "", pairingCode: "123456", sessionID: sessionID ?? "",
            kind: kind, body: body)
        sent.append(envelope)
        return envelope
    }
    func waitForClarification(taskID: String) async throws -> ComputerUseClarificationReference {
        for _ in 0..<200 {
            for message in sent where message.kind == .assistant {
                if let update = try? ComputerUseTaskUpdate.decodeBody(message.body),
                   update.taskID == taskID, let reference = update.clarification { return reference }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ContextTestFailure.timeout
    }
    func waitForApproval(taskID: String) async throws -> ComputerUseApprovalRequest {
        for _ in 0..<200 {
            for message in sent where message.kind == .approvalRequest {
                if let request = try? ComputerUseApprovalRequest.decodeBody(message.body), request.taskID == taskID {
                    return request
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ContextTestFailure.timeout
    }
    func diagnosticSummary() -> String { sent.map { envelope in guard let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) else { return String(describing: envelope.kind) }; return "\(envelope.kind):\(String(describing: update.outcome)):\(update.text)" }.joined(separator: " | ") }
    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
}

enum ContextTestFailure: Error { case timeout }

@MainActor
final class ContextRecordingPolicy: AgentPolicy {
    let promptVersion = "test"
    private(set) var seen: AgentObservation?
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        seen = observation
        return AgentPolicyOutput(rawOutput: "", action: .done(answer: "done"), rejectionReason: nil)
    }
    func stop() async {}
}

@MainActor
final class BlockingContextPolicy: AgentPolicy {
    let promptVersion = "blocking-context-test"
    private(set) var seen: AgentObservation?
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        seen = observation
        entered = true
        await withCheckedContinuation { releaseWaiter = $0 }
        return .init(rawOutput: "synthetic", action: .done(answer: "done"), rejectionReason: nil)
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func suspend() async {}
    func resume() async throws {}
    func stop() async { release() }
}

final class ContextTestKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    func add(_ item: ExactKeychainItem, data: Data) throws { lock.lock(); defer { lock.unlock() }; values[item] = data }
    func copy(_ item: ExactKeychainItem) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let data = values[item] else { throw KeychainBoundaryError.missingItem }; return data }
    func delete(_ item: ExactKeychainItem) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: item) }
    func replace(_ item: ExactKeychainItem, data: Data) throws { lock.lock(); defer { lock.unlock() }; guard values[item] != nil else { throw KeychainBoundaryError.missingItem }; values[item] = data }
}

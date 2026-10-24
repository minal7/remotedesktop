import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemoryTaskPolicyTests: XCTestCase {
    func testNewTaskCapturesChoicesAndNeverAddsThemToModelPrompt() async throws {
        let channel = TaskPolicyChannel()
        let store = TaskPolicyPendingStore()
        let model = makeModel(channel, store: store)
        model.start()
        model.noMemoryForNextTask = true
        model.incognitoForNextTask = true

        XCTAssertTrue(model.sendPrompt("Find a quiet hotel."))
        try await wait { await channel.promptCount == 1 }
        let request = try await channel.request(at: 0)
        let sentBody = try await channel.body(at: 0)
        XCTAssertEqual(request.memoryPolicy,
            ComputerUseTaskMemoryPolicy(noMemory: true, incognito: true))
        XCTAssertEqual(request.modelPrompt, "Find a quiet hotel.")
        XCTAssertEqual(store.current?.wireBody, sentBody)
        model.stop()
    }

    func testRecoveredRetryKeepsExactOriginalPolicyDespiteChangedControls() async throws {
        let channel = TaskPolicyChannel()
        let store = TaskPolicyPendingStore()
        let original = makeModel(channel, store: store)
        original.start()
        original.noMemoryForNextTask = false
        original.incognitoForNextTask = true
        XCTAssertTrue(original.sendPrompt("Check the weather."))
        try await wait { await channel.promptCount == 1 }
        let originalBody = try await channel.body(at: 0)
        original.stop()

        let recovered = makeModel(channel, store: store)
        recovered.noMemoryForNextTask = true
        recovered.incognitoForNextTask = false
        recovered.start()
        try await wait { await channel.promptCount == 2 }
        let retryBody = try await channel.body(at: 1)
        XCTAssertEqual(retryBody, originalBody)
        XCTAssertEqual(try ComputerUsePromptRequest.decodeBody(retryBody).memoryPolicy,
            ComputerUseTaskMemoryPolicy(incognito: true))
        recovered.stop()
    }

    func testClarificationAnswerInheritsAcceptedTaskPolicy() async throws {
        let channel = TaskPolicyChannel()
        let store = TaskPolicyPendingStore()
        let model = makeModel(channel, store: store)
        model.start()
        model.noMemoryForNextTask = true
        model.incognitoForNextTask = true
        XCTAssertTrue(model.sendPrompt("Find an open pharmacy."))
        try await wait { await channel.promptCount == 1 }

        let accepted = try await channel.request(at: 0)
        let expectedPolicy = ComputerUseTaskMemoryPolicy(noMemory: true, incognito: true)
        XCTAssertEqual(accepted.memoryPolicy, expectedPolicy)
        model.noMemoryForNextTask = false
        model.incognitoForNextTask = false
        let pending = try XCTUnwrap(store.current)
        let taskID = pending.messageID
        let reference = try ComputerUseClarificationReference(
            taskID: taskID, expiresAt: Date().addingTimeInterval(300))
        let update = ComputerUseTaskUpdate(taskID: taskID, text: "Which neighborhood?",
            outcome: .userInterventionRequired, clarification: reference,
            supportsClarificationRecovery: true)
        await channel.deliver(ComputerUseEnvelope(id: "update-1", senderID: "host",
            targetID: "phone", pairingCode: "pairing", sessionID: pending.sessionID,
            kind: .assistant, body: try update.encodedBody()))
        try await wait { if case .answer = model.composerMode { return true }; return false }

        XCTAssertTrue(model.sendPrompt("Oakland."))
        try await wait { await channel.promptCount == 2 }
        let answer = try await channel.request(at: 1)
        XCTAssertEqual(answer.clarification, reference)
        XCTAssertEqual(answer.memoryPolicy, expectedPolicy)
        model.stop()
    }

    func testSubsequentTaskUsesCurrentChoices() async throws {
        let channel = TaskPolicyChannel()
        let store = TaskPolicyPendingStore()
        let model = makeModel(channel, store: store)
        model.start()
        model.noMemoryForNextTask = true
        XCTAssertTrue(model.sendPrompt("Find a pharmacy."))
        try await wait { await channel.promptCount == 1 }
        let first = try await channel.request(at: 0)
        XCTAssertEqual(first.memoryPolicy, ComputerUseTaskMemoryPolicy(noMemory: true))
        let firstPending = try XCTUnwrap(store.current)
        await channel.deliver(ComputerUseEnvelope(id: "done-1", senderID: "host", targetID: "phone",
            pairingCode: "pairing", sessionID: firstPending.sessionID, kind: .assistant,
            body: try ComputerUseTaskUpdate(taskID: firstPending.messageID, text: "Done.", outcome: .taskCompleted).encodedBody()))
        try await wait { !model.hasActivePrompt && model.composerMode == .request }

        model.noMemoryForNextTask = false
        model.incognitoForNextTask = true
        XCTAssertTrue(model.sendPrompt("Find a grocery store."))
        try await wait { await channel.promptCount == 2 }
        let second = try await channel.request(at: 1)
        XCTAssertEqual(second.memoryPolicy, ComputerUseTaskMemoryPolicy(incognito: true))
        model.stop()
    }

    func testFeatureOffCannotAttachTaskMemoryPreferences() async throws {
        let channel = TaskPolicyChannel()
        let model = makeModel(channel, store: TaskPolicyPendingStore(), enabled: false)
        model.start()
        model.noMemoryForNextTask = true
        model.incognitoForNextTask = true
        XCTAssertFalse(model.showsTaskMemoryControls)
        XCTAssertNil(model.ownerMemory)
        XCTAssertTrue(model.sendPrompt("Open Calculator."))
        try await wait { await channel.promptCount == 1 }
        let request = try await channel.request(at: 0)
        XCTAssertEqual(request.memoryPolicy, ComputerUseTaskMemoryPolicy())
        model.stop()
    }

    private func makeModel(_ channel: TaskPolicyChannel, store: TaskPolicyPendingStore,
                           enabled: Bool = true) -> ComputerUseSessionModel {
        ComputerUseSessionModel(hostName: "Fixture", pairingCode: "pairing", hostID: "host",
            pendingStore: store, channel: channel, ownerMemoryDisplayEnabled: enabled,
            promptRefreshInterval: .seconds(3_600))
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw TaskPolicyChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor TaskPolicyChannel: ComputerUseSessionChannel, PersonalMemoryChannel {
    enum Failure: Error { case timeout }
    private(set) var promptBodies: [String] = []
    private var incoming: [ComputerUseEnvelope] = []
    var promptCount: Int { promptBodies.count }

    func send(kind: ComputerUseEnvelope.Kind, body: String, to explicitTargetID: String?,
              sessionID explicitSessionID: String?, messageID explicitMessageID: String?) async throws -> ComputerUseEnvelope {
        if kind == .prompt { promptBodies.append(body) }
        return ComputerUseEnvelope(id: explicitMessageID ?? UUID().uuidString, senderID: "host",
            targetID: "phone", pairingCode: "pairing", sessionID: explicitSessionID ?? "session",
            kind: kind, body: body)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        defer { incoming.removeAll() }
        return incoming
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        if command.operation == .captureMemoryGeneration {
            return .init(operation: command.operation, status: .completed,
                generationReference: String(repeating: "a", count: 64))
        }
        return .init(operation: command.operation, commandID: command.commandID,
            status: .completed, generationReference: command.generationReference)
    }

    func deliver(_ envelope: ComputerUseEnvelope) { incoming.append(envelope) }
    func body(at index: Int) throws -> String { try XCTUnwrap(promptBodies.indices.contains(index) ? promptBodies[index] : nil) }
    func request(at index: Int) throws -> ComputerUsePromptRequest {
        try ComputerUsePromptRequest.decodeBody(body(at: index))
    }
}

private final class TaskPolicyPendingStore: ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ComputerUsePendingPrompt?
    var current: ComputerUsePendingPrompt? { lock.lock(); defer { lock.unlock() }; return value }

    func read(hostID: String, pairingCode: String, localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt? { current }
    func readForLocalRecovery(hostID: String, localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? { current }
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? { current }
    func load(hostID: String, pairingCode: String, localAccountBinding: CloudKitAccountBinding?) -> ComputerUsePendingPrompt? { current }
    func loadForLocalRecovery(hostID: String, localAccountBinding: CloudKitAccountBinding) -> ComputerUsePendingPrompt? { current }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool { lock.lock(); defer { lock.unlock() }; value = pending; return true }
    func remove(ifMatching previous: ComputerUsePendingPrompt) -> ComputerUsePendingPromptMutationResult {
        lock.lock(); defer { lock.unlock() }
        guard value == previous else { return .conflict }
        value = nil
        return .applied
    }
    func remove(hostID: String) { lock.lock(); defer { lock.unlock() }; value = nil }
    func remove(hostID: String, localAccountBinding: CloudKitAccountBinding?) { remove(hostID: hostID) }
}

import Foundation

/// Structured prompt corruption must not turn into a fresh plain-text task.
/// The legacy fallback is reserved for bodies that are actually plain text.
enum ComputerUseExecutionPromptDecoder {
    enum Failure: Error { case invalidStructuredPrompt }
    static func decode(_ body: String) throws -> ComputerUsePromptRequest {
        let prefix = body.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard prefix.first == "{" || prefix.first == "[" else { return .init(prompt: body) }
        guard body.utf8.count <= 256 * 1_024 else { throw Failure.invalidStructuredPrompt }
        var parser = StrictSemanticJSONParser(prefix, maximumValueCount: 256)
        guard case .object(let object) = try parser.parse(),
              Set(object.keys).isSubset(of: ComputerUsePromptRequest.wireFieldNames) else { throw Failure.invalidStructuredPrompt }
        let request = try ComputerUsePromptRequest.decodeBody(prefix)
        guard request.version == ComputerUsePromptRequest.currentVersion,
              request.clarification == nil || request.conversation.isEmpty else { throw Failure.invalidStructuredPrompt }
        return request
    }
}

/// User-authored inputs remain separate, with exact bytes and explicit turn
/// boundaries. Questions are context, never a source of text-edit authority.
struct ComputerUseUnresolvedTextGoal: Equatable, Sendable {
    static let maximumUserTurns = 4
    static let maximumUserBytes = 32 * 1_024
    let userTurns: [String]
    let questions: [String]

    /// Contract identity only; never parse this value as user instructions.
    /// Single-turn identities remain compatible with existing text tasks.
    var taskIdentityText: String {
        guard userTurns.count > 1 else { return userTurns[0] }
        return "clarified-form-goal-v1:" + ComputerUseTaskContract.digest(
            [String(userTurns.count)] + userTurns + [String(questions.count)] + questions)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.userTurns.count == rhs.userTurns.count && lhs.questions.count == rhs.questions.count
            && zip(lhs.userTurns, rhs.userTurns).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            && zip(lhs.questions, rhs.questions).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    init(userRequest: String) throws {
        try Self.validate(userTurns: [userRequest], questions: [])
        userTurns = [userRequest]
        questions = []
    }

    private init(userTurns: [String], questions: [String]) throws {
        try Self.validate(userTurns: userTurns, questions: questions)
        self.userTurns = userTurns
        self.questions = questions
    }

    func answering(_ question: String, with answer: String) throws -> Self {
        try .init(userTurns: userTurns + [answer], questions: questions + [question])
    }

    private static func validate(userTurns: [String], questions: [String]) throws {
        guard (1...maximumUserTurns).contains(userTurns.count), questions.count == userTurns.count - 1,
              userTurns.allSatisfy({ !$0.isEmpty && $0.count <= ComputerUsePromptRequest.maximumPromptLength }),
              userTurns.reduce(0, { $0 + $1.utf8.count }) <= maximumUserBytes,
              questions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 * 1_024 }) else {
            throw ComputerUseTextClarificationStore.Failure.inputLimit
        }
    }
}

/// At most one in-memory, expiring clarification. Recreating this store after
/// a host restart expires all previous references; no transcript can rebuild
/// their authority. The caller still claims the answer's stable task ID in
/// the durable task ledger before consuming a reference.
@MainActor
final class ComputerUseTextClarificationStore {
    enum Failure: Error, Equatable { case invalidReference, expired, scopeChanged, inputLimit }
    private struct Pending {
        let reference: ComputerUseClarificationReference
        let senderID: String
        let sessionID: String
        let scope: String
        let question: String
        let goal: ComputerUseUnresolvedTextGoal
    }
    private var pending: Pending?
    private let now: () -> Date
    private var expiryTask: Task<Void, Never>?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    deinit { expiryTask?.cancel() }

    func issue(goal: ComputerUseUnresolvedTextGoal, question: String, scope: String,
               expiresAt: Date? = nil, for request: ComputerUseEnvelope) throws -> ComputerUseClarificationReference {
        let current = now(), expiry = min(expiresAt ?? current.addingTimeInterval(600), current.addingTimeInterval(600))
        guard request.kind == .prompt, !request.senderID.isEmpty, !request.sessionID.isEmpty, Self.validScope(scope),
              !question.isEmpty, question.utf8.count <= 8 * 1_024,
              goal.userTurns.count < ComputerUseUnresolvedTextGoal.maximumUserTurns,
              expiry.timeIntervalSinceReferenceDate.isFinite, expiry > current else { throw Failure.inputLimit }
        let reference = try ComputerUseClarificationReference(taskID: request.id, expiresAt: expiry)
        invalidate()
        pending = Pending(reference: reference, senderID: request.senderID, sessionID: request.sessionID,
            scope: scope, question: question, goal: goal)
        let lifetime = expiry.timeIntervalSince(current)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            guard let self, self.pending?.reference == reference else { return }
            self.invalidate()
        }
        return reference
    }

    func consume(_ reference: ComputerUseClarificationReference, answer: String, scope: String,
                 for request: ComputerUseEnvelope) throws -> ComputerUseUnresolvedTextGoal {
        guard request.kind == .prompt, let pending, pending.reference == reference,
              pending.senderID == request.senderID, pending.sessionID == request.sessionID,
              !request.id.isEmpty, request.id != reference.taskID else { throw Failure.invalidReference }
        guard now() < reference.expiresAt else { invalidate(); throw Failure.expired }
        guard pending.scope == scope else { invalidate(); throw Failure.scopeChanged }
        let goal = try pending.goal.answering(pending.question, with: answer)
        invalidate()
        return goal
    }

    func matches(_ reference: ComputerUseClarificationReference) -> Bool { pending?.reference == reference }

    /// The wire store and native executor must still hold the same unresolved
    /// goal, question and form scope. A saved terminal reply cannot recreate it.
    func retains(_ reference: ComputerUseClarificationReference, native: ComputerUseNativeTextExecutor.Clarification,
                 for request: ComputerUseEnvelope) -> Bool {
        guard let pending, pending.reference == reference, reference.taskID == request.id,
              pending.senderID == request.senderID, pending.sessionID == request.sessionID,
              now() < reference.expiresAt, reference.expiresAt <= native.expiresAt,
              native.taskID == request.id, native.scope == pending.scope, native.goal == pending.goal,
              native.question.utf8.elementsEqual(pending.question.utf8) else { return false }
        return true
    }

    func reference(for request: ComputerUseEnvelope) -> ComputerUseClarificationReference? {
        guard let pending, pending.reference.taskID == request.id,
              pending.senderID == request.senderID, pending.sessionID == request.sessionID else { return nil }
        guard now() < pending.reference.expiresAt else { invalidate(); return nil }
        return pending.reference
    }

    func invalidate(for request: ComputerUseEnvelope) {
        guard let pending, pending.reference.taskID == request.id,
              pending.senderID == request.senderID, pending.sessionID == request.sessionID else { return }
        invalidate()
    }

    func invalidate() { pending = nil; expiryTask?.cancel(); expiryTask = nil }

    private static func validScope(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

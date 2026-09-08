import Foundation

/// Host-authored task questions only. Account authentication continues to use
/// visible manual takeover, not this answer channel or model-authored text.
enum ComputerUseBrowserClarificationTopic: String, CaseIterable, Sendable {
    case origin, destination, location, date, time, quantity, currency, priceBasis, fees, source
    var question: String {
        switch self {
        case .origin: return "Where will you be traveling from?"
        case .destination: return "Which destination should I use?"
        case .location: return "Which city or area should I search?"
        case .date: return "Which date or date range do you mean? You can use YYYY-MM-DD."
        case .time: return "What local time or time range should I use?"
        case .quantity: return "How many results, tickets or people do you mean? Please specify which, and adult/child counts when relevant."
        case .currency: return "Which currency do you mean? Please give its three-letter code."
        case .priceBasis: return "Is the budget a total, per person or per ticket?"
        case .fees: return "Should the price limit include fees?"
        case .source: return "Which exact websites should I include or exclude, and does that limit the pages I may visit or only the sources of the results I report? Please include the domain names."
        }
    }
    func accepts(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        if self == .source, scopeFields.contains(requirement.field),
           requirement.role == .prohibition || requirement.role == .order { return true }
        if requirement.role == .outcome { return true } // A missing detail may have no separate source clause.
        guard requirement.role == .condition || requirement.role == .clarification else { return false }
        return scopeFields.contains(requirement.field)
    }
    var scopeFields: [ComputerUseBrowserGoalProposal.Field] {
        switch self {
        case .origin: return [.origin]
        case .destination: return [.destination]
        case .location: return [.location]
        case .date: return [.date]
        case .time: return [.time]
        case .quantity: return [.quantity]
        case .currency, .priceBasis: return [.price]
        case .fees: return [.fees, .price]
        case .source: return [.source, .navigationSource, .answerSource]
        }
    }
}

/// Exact user answer plus typed question context. Construction is restricted
/// to consumption of a live question; source coverage never includes questions.
struct ComputerUseBrowserGoalClarificationTurn: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Scope: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let requirementID: String
        let turn: Int
        let sourceByteOffset: Int
        let source: String
        fileprivate init(requirement: ComputerUseBrowserGoalProposal.Requirement, source: String) {
            requirementID = requirement.id; turn = requirement.sourceTurnIndex
            sourceByteOffset = requirement.sourceByteOffset; self.source = source
        }
        var description: String { "BrowserClarificationScope" }
        var debugDescription: String { description }
    }
    let inputDigest: String
    let questionID: String
    let topic: ComputerUseBrowserClarificationTopic
    let scope: [Scope]
    let answerTaskID: String
    let answer: String
    let digest: String
    fileprivate init(question: ComputerUseBrowserGoalClarification.Question, answerTaskID: String, answer: String) {
        inputDigest = question.inputDigest; questionID = question.id; topic = question.topic; scope = question.scope
        self.answerTaskID = answerTaskID; self.answer = answer
        digest = ComputerUseTaskContract.digest(["browser-goal-answer-v1", inputDigest, questionID, answerTaskID, answer])
    }
    var description: String { "BrowserClarificationTurn(topic: \(topic.rawValue), bytes: \(answer.utf8.count))" }
    var debugDescription: String { description }
}

/// In-memory clarification state for one browser root. The host must supply
/// authenticated controller/session context and, after browser creation, its
/// actual session binding. Equality here does not establish live ownership.
/// The durable transport ledger must claim the answer ID before consumption.
@MainActor
final class ComputerUseBrowserGoalClarification {
    enum Failure: Error, Equatable { case invalidReference, expired, contextChanged, invalidProposal, inputLimit, retired, questionPending }
    struct Context: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        private let digest: String
        init(controllerID: String, controllerSessionID: String, browserSessionDigest: String?) throws {
            guard Self.validIdentifier(controllerID), Self.validIdentifier(controllerSessionID),
                  browserSessionDigest.map(Self.validDigest) ?? true else { throw Failure.inputLimit }
            digest = ComputerUseTaskContract.digest(["browser-clarification-context-v1", controllerID, controllerSessionID,
                browserSessionDigest == nil ? "before-browser" : "browser", browserSessionDigest ?? ""])
        }
        fileprivate var identity: String { digest }
        fileprivate static func validIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        private static func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        var description: String { "BrowserClarificationContext" }
        var debugDescription: String { description }
    }
    struct Question: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let taskID: String
        let inputDigest: String
        let topic: ComputerUseBrowserClarificationTopic
        let scope: [ComputerUseBrowserGoalClarificationTurn.Scope]
        let expiresAt: Date
        let context: Context
        var text: String { topic.question }
        fileprivate init(input: ComputerUseBrowserGoalInput, topic: ComputerUseBrowserClarificationTopic,
                         scope: [ComputerUseBrowserGoalClarificationTurn.Scope], expiresAt: Date, context: Context) {
            taskID = input.taskID; inputDigest = input.digest; self.topic = topic; self.scope = scope
            self.expiresAt = expiresAt; self.context = context
            id = ComputerUseTaskContract.digest(["browser-goal-question-v1", UUID().uuidString, input.digest,
                topic.rawValue, context.identity, String(expiresAt.timeIntervalSince1970)] + scope.map(\.requirementID))
        }
        var description: String { "BrowserGoalQuestion(topic: \(topic.rawValue))" }
        var debugDescription: String { description }
    }

    private(set) var input: ComputerUseBrowserGoalInput
    private var pending: Question?
    private var isRetired = false
    private let now: () -> Date
    init(input: ComputerUseBrowserGoalInput, now: @escaping () -> Date = Date.init) { self.input = input; self.now = now }

    /// A typed host topic selects fixed question text. Scope validation is
    /// structural, not proof that this is the right semantic clarification
    /// for the user's complete goal.
    func issue(proposal: ComputerUseBrowserGoalProposal, topic: ComputerUseBrowserClarificationTopic,
               requirementIDs: [String], context: Context) throws -> Question {
        guard !isRetired else { throw Failure.retired }
        let current = try currentDate()
        if let pending, current >= pending.expiresAt { self.pending = nil }
        guard pending == nil else { throw Failure.questionPending }
        guard input.userTurns.count < ComputerUseBrowserGoalInput.maximumUserTurns,
              input.userTurns.reduce(0, { $0 + $1.utf8.count }) < ComputerUseBrowserGoalInput.maximumUserBytes else { throw Failure.inputLimit }
        guard proposal.input.digest == input.digest, proposal.disposition != .unsupported,
              (1...8).contains(requirementIDs.count), Set(requirementIDs).count == requirementIDs.count else { throw Failure.invalidProposal }
        let requirements = proposal.requirements.filter { requirementIDs.contains($0.id) }
        guard requirements.count == requirementIDs.count, requirements.allSatisfy(topic.accepts) else { throw Failure.invalidProposal }
        let scope = try requirements.map { requirement -> ComputerUseBrowserGoalClarificationTurn.Scope in
            guard let source = proposal.source(of: requirement) else { throw Failure.invalidProposal }
            return .init(requirement: requirement, source: source)
        }
        let expiry = current.addingTimeInterval(600)
        guard expiry.timeIntervalSince1970.isFinite, expiry > current else { throw Failure.inputLimit }
        let question = Question(input: input, topic: topic, scope: scope, expiresAt: expiry, context: context)
        pending = question
        return question
    }

    func consume(questionID: String, answerTaskID: String, answer: String, context: Context) throws -> ComputerUseBrowserGoalInput {
        guard !isRetired else { throw Failure.retired }
        guard let question = pending, question.id == questionID, question.inputDigest == input.digest else { throw Failure.invalidReference }
        guard try currentDate() < question.expiresAt else { pending = nil; throw Failure.expired }
        guard question.context == context else { throw Failure.contextChanged }
        guard Context.validIdentifier(answerTaskID) else { throw Failure.inputLimit }
        let turn = ComputerUseBrowserGoalClarificationTurn(question: question, answerTaskID: answerTaskID, answer: answer)
        let continued: ComputerUseBrowserGoalInput
        do { continued = try input.appending(turn) } catch { throw Failure.inputLimit }
        // Only a fully validated answer consumes the reference. Failed input
        // admission leaves the question available for correction.
        input = continued; pending = nil
        return continued
    }

    func pendingQuestion(context: Context) throws -> Question? {
        guard !isRetired else { throw Failure.retired }
        guard let pending else { return nil }
        guard try currentDate() < pending.expiresAt else { self.pending = nil; throw Failure.expired }
        guard pending.context == context else { throw Failure.contextChanged }
        return pending
    }

    /// Pause/session loss may invalidate a question without discarding the
    /// original goal or accepted answers. Stop/replacement retires the owner.
    func invalidateQuestion() { pending = nil }
    func retire() { isRetired = true; pending = nil }
    private func currentDate() throws -> Date {
        let value = now()
        guard value.timeIntervalSince1970.isFinite else { throw Failure.inputLimit }
        return value
    }
}

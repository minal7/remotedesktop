import Foundation

/// Host-authored task questions only. Account authentication continues to use
/// visible manual takeover, not this answer channel or model-authored text.
enum ComputerUseBrowserClarificationTopic: String, CaseIterable, Sendable {
    case origin, destination, location, date, replaceDate, time, quantity, currency, priceBasis, fees, source
    var isDateTopic: Bool { self == .date || self == .replaceDate }
    var question: String {
        switch self {
        case .origin: return "Where will you be traveling from?"
        case .destination: return "Which destination should I use?"
        case .location: return "Which city or area should I search?"
        case .date: return "Which date or date range do you mean? You can use YYYY-MM-DD."
        case .replaceDate: return "What date or date range should replace the selected date requirement? This replaces that whole date requirement, including its weekday or before/after limit. Other requirements stay in place. You can use YYYY-MM-DD."
        case .time: return "What local time or time range should I use?"
        case .quantity: return "How many results, tickets or people do you mean? Please specify which, and adult/child counts when relevant."
        case .currency: return "Which currency do you mean? Please give its three-letter code."
        case .priceBasis: return "Is the budget a total, per person or per ticket?"
        case .fees: return "Should the price limit include fees?"
        case .source: return "Which exact websites should I include or exclude, and does that limit the pages I may visit or only the sources of the results I report? Please include the domain names."
        }
    }
    func accepts(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        if self == .replaceDate { return false } // Native source lineage, not model labels, admits replacements.
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
        case .date, .replaceDate: return [.date]
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
    /// Historical classification of every clause, including clauses outside
    /// the question's scope. A later answer cannot erase this provenance.
    let priorInterpretationDigest: String
    let priorRequirements: [ComputerUseBrowserGoalProposal.Requirement]
    let answerTaskID: String
    let answer: String
    let dateContext: ComputerUseBrowserGoalInput.DateContext
    let digest: String
    fileprivate init(question: ComputerUseBrowserGoalClarification.Question, answerTaskID: String, answer: String,
                     dateContext: ComputerUseBrowserGoalInput.DateContext) {
        inputDigest = question.inputDigest; questionID = question.id; topic = question.topic; scope = question.scope
        priorInterpretationDigest = question.interpretationDigest; priorRequirements = question.requirements
        self.answerTaskID = answerTaskID; self.answer = answer; self.dateContext = dateContext
        digest = ComputerUseTaskContract.digest(["browser-goal-answer-v3", inputDigest, questionID,
            priorInterpretationDigest, answerTaskID, answer, String(dateContext.referenceMilliseconds), dateContext.timeZoneIdentifier])
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
        let interpretationDigest: String
        let requirements: [ComputerUseBrowserGoalProposal.Requirement]
        let issuedAt: Date
        let expiresAt: Date
        let context: Context
        let text: String
        fileprivate init(proposal: ComputerUseBrowserGoalProposal, topic: ComputerUseBrowserClarificationTopic,
                         scope: [ComputerUseBrowserGoalClarificationTurn.Scope], issuedAt: Date, expiresAt: Date, context: Context) throws {
            let input = proposal.input
            taskID = input.taskID; inputDigest = input.digest; self.topic = topic; self.scope = scope
            interpretationDigest = proposal.digest; requirements = proposal.requirements
            self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.context = context
            text = try Self.render(topic: topic, scope: scope, input: input)
            guard text.count <= ComputerUseTaskLedger.maximumClarificationCharacters,
                  text.utf8.count <= ComputerUseTaskLedger.maximumClarificationUTF8Bytes else { throw Failure.inputLimit }
            id = ComputerUseTaskContract.digest(["browser-goal-question-v3", UUID().uuidString, input.digest, proposal.digest,
                topic.rawValue, text, context.identity, String(expiresAt.timeIntervalSince1970)] + scope.map(\.requirementID))
        }
        private static func render(topic: ComputerUseBrowserClarificationTopic,
                                   scope: [ComputerUseBrowserGoalClarificationTurn.Scope], input: ComputerUseBrowserGoalInput) throws -> String {
            let excerpts = try scope.map { item -> String in
                guard input.userTurns.indices.contains(item.turn) else { throw Failure.invalidProposal }
                let bytes = Data(input.userTurns[item.turn].utf8), start = item.sourceByteOffset
                let length = item.source.utf8.count
                guard start >= 0, start <= bytes.count, length <= bytes.count - start else { throw Failure.invalidProposal }
                let end = start + length
                guard Data(bytes[start..<end]) == Data(item.source.utf8),
                      let prefix = String(data: bytes.prefix(start), encoding: .utf8),
                      let suffix = String(data: bytes.suffix(bytes.count - end), encoding: .utf8) else { throw Failure.invalidProposal }
                let before = contextExcerpt(prefix, fromEnd: true), after = contextExcerpt(suffix, fromEnd: false)
                let excerpt = (before.omitted ? "…" : "") + display(before.text) + "⟦" + display(item.source) + "⟧"
                    + display(after.text) + (after.omitted ? "…" : "")
                var label = item.turn == 0 ? "From your request" : "From your answer \(item.turn)"
                if topic.isDateTopic {
                    guard let reference = input.dateContext(forTurn: item.turn) else { throw Failure.invalidProposal }
                    label += " (relative dates use \(reference.civilDateLabel) in \(reference.timeZoneIdentifier))"
                }
                return "\(label):\n“\(excerpt)”"
            }
            let answerClock = topic.isDateTopic
                ? "\n\nFor words like today or tomorrow, your answer uses the date I receive it in \(input.timeZoneIdentifier). Earlier messages keep their original date references."
                : ""
            return topic.question + answerClock + "\n\nI'm asking about the part inside ⟦ ⟧.\n\n" + excerpts.joined(separator: "\n\n")
        }
        /// Nearby context distinguishes repeated clauses. Only context is
        /// shortened; every selected source scalar has a display representation.
        private static func contextExcerpt(_ source: String, fromEnd: Bool) -> (text: String, omitted: Bool) {
            var selected: [Character] = [], scalars = 0
            func append(_ character: Character) -> Bool {
                let count = character.unicodeScalars.count
                guard scalars + count <= 64 else { return false }
                selected.append(character); scalars += count
                return true
            }
            if fromEnd { for character in source.reversed() { if !append(character) { break } } }
            else { for character in source { if !append(character) { break } } }
            let text = fromEnd ? String(selected.reversed()) : String(selected)
            return (text, text.utf8.count != source.utf8.count)
        }
        /// A display projection only. Original source/answer bytes remain
        /// untouched in the sealed scope and structured model input.
        private static func display(_ source: String) -> String {
            var result = ""
            for scalar in source.unicodeScalars {
                switch scalar.value {
                case 0...31: result.unicodeScalars.append(UnicodeScalar(0x2400 + scalar.value)!)
                case 127: result.append("␡")
                case 128...159, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: result.append("�")
                case 0x2028: result.append("⏎")
                case 0x2029: result.append("¶")
                case 0x27E6: result.append("［")
                case 0x27E7: result.append("］")
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result
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
        let selected = proposal.requirements.filter { requirementIDs.contains($0.id) }
        guard selected.count == requirementIDs.count,
              proposal.permitsQuestion(topic: topic, requirements: selected) else { throw Failure.invalidProposal }
        let requirements: [ComputerUseBrowserGoalProposal.Requirement]
        if topic == .replaceDate {
            // A confirmation/conflict answer can point at an earlier date.
            // Display and bind the actual origin being replaced, not just the
            // later literal the model happened to select.
            guard let origins = proposal.dateReplacementTargets(for: selected) else { throw Failure.invalidProposal }
            requirements = origins
        } else { requirements = selected }
        let scope = try requirements.map { requirement -> ComputerUseBrowserGoalClarificationTurn.Scope in
            guard let source = proposal.source(of: requirement) else { throw Failure.invalidProposal }
            return .init(requirement: requirement, source: source)
        }
        let expiry = current.addingTimeInterval(600)
        guard expiry.timeIntervalSince1970 < ComputerUseBrowserGoalInput.DateContext.maximumSeconds, expiry > current else { throw Failure.inputLimit }
        let question = try Question(proposal: proposal, topic: topic, scope: scope, issuedAt: current, expiresAt: expiry, context: context)
        pending = question
        return question
    }

    func consume(questionID: String, answerTaskID: String, answer: String, context: Context) throws -> ComputerUseBrowserGoalInput {
        guard !isRetired else { throw Failure.retired }
        guard let question = pending, question.id == questionID, question.inputDigest == input.digest else { throw Failure.invalidReference }
        let acceptedAt = try currentDate()
        guard acceptedAt < question.expiresAt else { pending = nil; throw Failure.expired }
        guard acceptedAt >= question.issuedAt else { throw Failure.inputLimit }
        guard question.context == context else { throw Failure.contextChanged }
        guard Context.validIdentifier(answerTaskID) else { throw Failure.inputLimit }
        let dateContext = try ComputerUseBrowserGoalInput.DateContext(referenceDate: acceptedAt, timeZoneIdentifier: input.timeZoneIdentifier)
        let turn = ComputerUseBrowserGoalClarificationTurn(question: question, answerTaskID: answerTaskID, answer: answer, dateContext: dateContext)
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
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < ComputerUseBrowserGoalInput.DateContext.maximumSeconds else { throw Failure.inputLimit }
        return value
    }
}

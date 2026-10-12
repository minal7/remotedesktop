import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserWorkBudgetTests: XCTestCase {
    func testActiveSegmentsAccumulateWithoutChargingManualTimeOrRefillingOnFinish() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); clock.advance(.seconds(4)); budget.finish(); budget.finish()
        clock.advance(.seconds(3_600)); try budget.begin()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 6, accuracy: 0.000_001)
        clock.advance(.seconds(6))
        XCTAssertThrowsError(try budget.admit()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        budget.finish(); clock.advance(.seconds(3_600))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        XCTAssertThrowsError(try budget.planningTimeout(maximum: 30), "An inactive owner cannot bypass exhausted capacity")
    }

    func testRepeatedCheckpointsChargeEachActiveIntervalOnlyOnce() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }
        clock.advance(.seconds(2)); try budget.admit(); try budget.admit()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 8, accuracy: 0.000_001)
        clock.advance(.seconds(3)); try budget.admit()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 5, accuracy: 0.000_001)
        XCTAssertEqual(try budget.planningTimeout(maximum: 2), 2, accuracy: 0.000_001)
    }

    func testOverlappingBeginCannotReplaceAnActiveSegmentOrRefundItsTime() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }; clock.advance(.seconds(3))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .alreadyActive) }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 7, accuracy: 0.000_001)
    }

    func testInvalidAllowancesFailBeforeOpeningASegment() {
        for allowance in [Duration.zero, .seconds(-1), ComputerUseBrowserWorkBudget.maximumAllowance + .seconds(1)] {
            var clockCalls = 0
            let budget = ComputerUseBrowserWorkBudget(allowance: allowance, clock: { clockCalls += 1; return .now })
            XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .invalidAllowance) }
            XCTAssertThrowsError(try budget.planningTimeout(maximum: 30))
            budget.finish(); XCTAssertEqual(clockCalls, 0)
        }
    }

    func testRegressedClockCannotRefundOrReviveWorkCapacity() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); clock.advance(.seconds(-1))
        XCTAssertThrowsError(try budget.admit()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        budget.finish(); clock.advance(.seconds(3_600))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
    }

    func testProposalAllowanceUsesRemainingFractionalTimeAndRejectsInvalidStageLimits() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .milliseconds(150), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.15, accuracy: 0.000_001)
        clock.advance(.milliseconds(100))
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.05, accuracy: 0.000_001)
        for maximum in [0, -1, .infinity, .nan, ComputerUsePlanningWorker.maximumWait + 1] {
            XCTAssertThrowsError(try budget.planningTimeout(maximum: maximum)) {
                XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .invalidDeadline)
            }
        }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.05, accuracy: 0.000_001)
    }
}

@MainActor
final class BrowserWorkFixtureClock {
    var instant = ContinuousClock.now
    func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

@MainActor
enum ResearchDriverFixture {
    static let root = "research-driver"
    static let prompt = "Find concerts under USD 50. Do not buy."
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class DriverFixtureState {
    var allowed = true
    var commands: [ComputerUseBrowserDOMCommand] = []
    var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
    var onMayAct: (() -> Void)?
    var writes = 0
    var onWrite: (() -> Void)?
    var failureAtWrite: Int?
}

@MainActor
final class DriverGoalFixture: ComputerUseBrowserGoalPlanning {
    let base = BrowserResearchGoalFixture()
    var select: ((ComputerUseBrowserGoalInput) throws -> String)?
    var unsupported = false
    var inputs: [ComputerUseBrowserGoalInput] = []
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        inputs.append(input)
        if let select { return try .decode(content: select(input), input: input) }
        if !unsupported { return try await base.propose(input) }
        let rows: [[String: Any]] = input.userTurns.enumerated().map {
            ["turn":$0.offset, "source":$0.element, "role":"unsupported", "field":"other", "relation":"unspecified", "values":[]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"unsupported", "requirements":rows,
            "question":["topic":"none", "requirements":[]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
final class DriverSearchFixture: ComputerUseBrowserSearchPlanning {
    var inputs: [ComputerUseBrowserGoalProposal] = []
    var empty = false
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery {
        inputs.append(interpretation)
        if let beforeReply { await beforeReply() }
        return try .decode(content: empty ? #"{"terms":[]}"# : #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: interpretation)
    }
}

@MainActor
final class DriverPlanningFixture: ComputerUseBrowserResearchPlanning {
    let provider: ComputerUseBrowserSearchProvider
    var providerEnabled = true
    var providerCalls = 0
    var choices: [Bool] = []
    var invalidChoice = false
    var allowedOrigins: [ComputerUseBrowserSourceOrigin]?
    var excludedOrigins: [ComputerUseBrowserSourceOrigin] = []
    var answerExcludedOrigins: [ComputerUseBrowserSourceOrigin] = []
    var goals: [ComputerUseBrowserGoalInput] = []
    var histories: [[ComputerUseBrowserResearchVisit]] = []
    var evidenceSnapshots: [ComputerUseBrowserResearchEvidence?] = []
    var beforeSelection: (@MainActor () async -> Void)?
    init(provider: ComputerUseBrowserSearchProvider) { self.provider = provider }
    func sources(for interpretation: ComputerUseBrowserResearchTask.Interpretation) throws -> ComputerUseBrowserResearchSources? {
        providerCalls += 1
        guard providerEnabled else { return nil }
        return try .init(goal: interpretation.proposal.input, provider: provider, allowedOrigins: allowedOrigins,
            excludedOrigins: excludedOrigins, answerExcludedOrigins: answerExcludedOrigins)
    }
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence? = nil) async throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        goals.append(goal); histories.append(history); evidenceSnapshots.append(evidence)
        if let beforeSelection { await beforeSelection() }
        guard !choices.isEmpty, choices.removeFirst() else { return nil }
        let candidate = try XCTUnwrap(candidates.candidates.first)
        if invalidChoice { return .init(candidateID: candidate.id, linkID: "not-observed") }
        return .init(candidateID: candidate.id, linkID: try XCTUnwrap(candidate.selectedLinkIDs.first))
    }
}

@MainActor
final class BrowserResearchActionFixture: ComputerUseBrowserActionPlanning {
    var select: ((ComputerUseBrowserActionInput) throws -> String)?
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserActionInput] = []
    private(set) var steps: [ComputerUseBrowserActionProposal.Step] = []
    func propose(_ input: ComputerUseBrowserActionInput) async throws -> ComputerUseBrowserActionProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        let proposal = try ComputerUseBrowserActionProposal.decode(content: select?(input) ?? #"{"read_results":true}"#, input: input)
        steps.append(proposal.step)
        return proposal
    }
}
@MainActor
final class BrowserResearchFormFixture: ComputerUseBrowserFormPlanning {
    var select: ((ComputerUseBrowserResearchFormInput) throws -> String)?
    var content = #"{"unavailable":true}"#
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserResearchFormInput] = []
    func propose(_ input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserFormProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        return try .decode(content: select?(input) ?? content, input: input)
    }
}

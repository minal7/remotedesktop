import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentJournalTests: XCTestCase {
    func testUncertainEffectBlocksReplayAfterRunnerReopens() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: AgentJournal? = try AgentJournal(taskID: "fixture-task", prompt: "generic task",
                                                      maxSteps: 3, directory: directory)
        let fingerprint = String(repeating: "a", count: 64)
        try journal?.begin(step: 0, fingerprint: fingerprint)
        try journal?.markUncertain(step: 0, fingerprint: fingerprint)
        XCTAssertThrowsError(try journal?.assertMayContinue()) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .uncertainEffect = failure else { return XCTFail("Unexpected error: \(error)") }
        }

        journal = nil
        XCTAssertThrowsError(try AgentJournal(taskID: "fixture-task", prompt: "generic task",
                                               maxSteps: 3, directory: directory)) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .uncertainEffect = failure else { return XCTFail("Uncertain journal was replayable: \(error)") }
        }
    }

    func testTaskLeaseExcludesCompetingRunnerUntilVerifiedOwnerReleases() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: AgentJournal? = try AgentJournal(taskID: "lease-fixture", prompt: "generic task",
                                                    maxSteps: 3, directory: directory)

        XCTAssertThrowsError(try AgentJournal(taskID: "lease-fixture", prompt: "generic task",
                                               maxSteps: 3, directory: directory)) { error in
            guard let failure = error as? ComputerUseTaskJournalStore.StoreError,
                  case .busy = failure else { return XCTFail("Unexpected error: \(error)") }
        }

        first = nil
        let resumed = try AgentJournal(taskID: "lease-fixture", prompt: "generic task",
                                       maxSteps: 3, directory: directory)
        try resumed.assertMayContinue()
    }

    func testVerifiedStepsPermitContinuationAndCannotBePerformedTwice() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: AgentJournal? = try AgentJournal(taskID: "verified-fixture", prompt: "generic task",
                                                      maxSteps: 3, directory: directory)
        let firstFingerprint = String(repeating: "b", count: 64)
        try journal?.begin(step: 0, fingerprint: firstFingerprint)
        try journal?.verify(step: 0, fingerprint: firstFingerprint)
        try journal?.assertMayContinue()

        let secondFingerprint = String(repeating: "c", count: 64)
        try journal?.begin(step: 1, fingerprint: secondFingerprint)
        try journal?.verify(step: 1, fingerprint: secondFingerprint)
        try journal?.assertMayContinue()
        XCTAssertThrowsError(try journal?.begin(step: 0, fingerprint: firstFingerprint)) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .alreadyPerformed = failure else { return XCTFail("Verified step was not recognized: \(error)") }
        }

        journal = nil
        let reopened = try AgentJournal(taskID: "verified-fixture", prompt: "generic task",
                                        maxSteps: 3, directory: directory)
        try reopened.assertMayContinue()
        XCTAssertThrowsError(try reopened.begin(step: 1, fingerprint: secondFingerprint)) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .alreadyPerformed = failure else { return XCTFail("Verified step was replayable: \(error)") }
        }
    }

    func testPromptOrFingerprintMismatchCannotResumeAnExistingEffect() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: AgentJournal? = try AgentJournal(taskID: "mismatch-fixture", prompt: "first prompt",
                                                      maxSteps: 2, directory: directory)
        let fingerprint = String(repeating: "d", count: 64)
        try journal?.begin(step: 0, fingerprint: fingerprint)
        try journal?.verify(step: 0, fingerprint: fingerprint)
        journal = nil

        XCTAssertThrowsError(try AgentJournal(taskID: "mismatch-fixture", prompt: "changed prompt",
                                               maxSteps: 2, directory: directory)) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .mismatch = failure else { return XCTFail("Changed prompt reused task state: \(error)") }
        }
        let samePrompt = try AgentJournal(taskID: "mismatch-fixture", prompt: "first prompt",
                                          maxSteps: 2, directory: directory)
        XCTAssertThrowsError(try samePrompt.begin(step: 0, fingerprint: String(repeating: "e", count: 64))) { error in
            guard let failure = error as? AgentJournal.Failure,
                  case .mismatch = failure else { return XCTFail("Changed fingerprint reused a verified step: \(error)") }
        }
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
}

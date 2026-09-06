import Foundation
import Darwin
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseTextStepStoreTests: XCTestCase {
    func testStaleWriterCannotOverwriteNewAttemptOrVerifiedProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ComputerUseTextStepStore(directory: directory), second = try ComputerUseTextStepStore(directory: directory)
        let original = journal([.attempted, .planned])
        XCTAssertNil(try first.load(taskID: "task")); XCTAssertNil(try second.load(taskID: "task"))
        try first.save(original, replacing: nil)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        let saved = try Data(contentsOf: file)
        XCTAssertThrowsError(try second.save(original, replacing: nil)) {
            XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .staleJournal)
        }
        XCTAssertEqual(try Data(contentsOf: file), saved)
        let recovered = try XCTUnwrap(second.load(taskID: "task")), verified = journal([.verified, .planned])
        try first.save(verified, replacing: original)
        XCTAssertThrowsError(try second.save(journal([.uncertain, .planned]), replacing: recovered)) {
            XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .staleJournal)
        }
        XCTAssertEqual(try second.load(taskID: "task"), verified)
        let next = journal([.verified, .attempted])
        try second.save(next, replacing: verified)
        let finished = journal([.verified, .verified])
        try second.save(finished, replacing: next)
        try second.save(finished, replacing: finished)
        XCTAssertEqual(try first.load(taskID: "task"), finished)
    }

    func testJournalCannotRewindSkipAnAttemptOrChangeItsBoundContract() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory)
        for statuses in [[ComputerUseTaskStepStatus.verified, .planned], [.uncertain, .planned], [.verified, .attempted]] {
            XCTAssertThrowsError(try store.save(journal(statuses), replacing: nil)) {
                XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .invalidTransition)
            }
        }
        XCTAssertNil(try store.load(taskID: "task"))
        let attempted = journal([.attempted, .planned])
        try store.save(attempted, replacing: nil)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        let saved = try Data(contentsOf: file)
        let changedPrompt = ComputerUseTextStepJournal(taskID: attempted.taskID, promptDigest: ComputerUseTextTaskContract.digest("changed"),
            contractDigest: attempted.contractDigest, stepIDs: attempted.stepIDs, statuses: [.verified, .planned])
        let changedContract = ComputerUseTextStepJournal(taskID: attempted.taskID, promptDigest: attempted.promptDigest,
            contractDigest: ComputerUseTextTaskContract.digest("changed"), stepIDs: attempted.stepIDs, statuses: [.verified, .planned])
        let changedStep = ComputerUseTextStepJournal(taskID: attempted.taskID, promptDigest: attempted.promptDigest,
            contractDigest: attempted.contractDigest, stepIDs: ["é", "step-2"], statuses: [.verified, .planned])
        for invalid in [journal([.planned, .planned]), journal([.verified, .attempted]), changedPrompt, changedContract, changedStep] {
            XCTAssertThrowsError(try store.save(invalid, replacing: attempted)) {
                XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .invalidTransition)
            }
            XCTAssertEqual(try Data(contentsOf: file), saved)
        }
        let uncertain = journal([.uncertain, .planned])
        try store.save(uncertain, replacing: attempted)
        try store.save(uncertain, replacing: uncertain)
        XCTAssertThrowsError(try store.save(attempted, replacing: uncertain))
        try store.save(journal([.verified, .planned]), replacing: uncertain)
    }

    func testCompetingStoreCannotReadOrAdvanceDuringAtomicReplacementAndLockSurvivesRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let competing = try ComputerUseTextStepStore(directory: directory)
        let attempted = journal([.attempted, .planned])
        var callbacks = 0
        let writer = try ComputerUseTextStepStore(directory: directory, afterReplacement: {
            callbacks += 1
            XCTAssertThrowsError(try competing.load(taskID: "task")) {
                XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .busy)
            }
            XCTAssertThrowsError(try competing.save(attempted, replacing: nil)) {
                XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .busy)
            }
            XCTAssertNil(try competing.load(taskID: "unrelated-task"), "The OS lock is scoped to this journal")
        })
        try writer.save(attempted, replacing: nil)
        let lockFile = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".lock")
        let before = try FileManager.default.attributesOfItem(atPath: lockFile.path)
        try writer.save(journal([.verified, .planned]), replacing: attempted)
        let after = try FileManager.default.attributesOfItem(atPath: lockFile.path)
        XCTAssertEqual(try XCTUnwrap(before[.systemFileNumber] as? NSNumber), try XCTUnwrap(after[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(try competing.load(taskID: "task")?.statuses, [.verified, .planned])
        XCTAssertThrowsError(try competing.save(attempted, replacing: nil)) {
            XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .staleJournal)
        }
    }

    func testReplacementFailureRetainsVisibleAttemptAndPoisonsTheWriterUntilReconstruction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fail = true
        let writer = try ComputerUseTextStepStore(directory: directory, afterReplacement: {
            if fail { throw ComputerUseTextStepStore.StoreError.unavailable }
        })
        let attempted = journal([.attempted, .planned])
        XCTAssertThrowsError(try writer.save(attempted, replacing: nil))
        fail = false
        XCTAssertThrowsError(try writer.load(taskID: "task"))
        XCTAssertThrowsError(try writer.save(attempted, replacing: nil))
        let reopened = try ComputerUseTextStepStore(directory: directory)
        XCTAssertEqual(try reopened.load(taskID: "task"), attempted)
        XCTAssertThrowsError(try reopened.save(attempted, replacing: nil)) {
            XCTAssertEqual($0 as? ComputerUseTextStepStore.StoreError, .staleJournal)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testJournalAndLockAliasesOrUnsafeFilesCannotAuthorizeWrites() throws {
        for (suffix, kind) in [".json", ".lock"].flatMap({ suffix in
            ["symlink", "hardlink", "directory", "permissions", "fifo"].map { (suffix, $0) }
        }) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ComputerUseTextStepStore(directory: directory)
            let invalidFile = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + suffix)
            let protected = directory.appendingPathComponent("retained-file")
            try Data("Retained fixture".utf8).write(to: protected)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protected.path)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: invalidFile, withDestinationURL: protected)
            case "hardlink": try FileManager.default.linkItem(at: protected, to: invalidFile)
            case "directory": try FileManager.default.createDirectory(at: invalidFile, withIntermediateDirectories: false)
            case "fifo": XCTAssertEqual(invalidFile.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
            default:
                try Data().write(to: invalidFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: invalidFile.path)
            }
            XCTAssertThrowsError(try store.load(taskID: "task"), kind)
            XCTAssertThrowsError(try store.save(journal([.attempted, .planned]), replacing: nil), kind)
            XCTAssertEqual(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory), suffix == ".json")
            XCTAssertEqual(try Data(contentsOf: protected), Data("Retained fixture".utf8))
        }
    }

    func testMalformedJournalIdentityAndImpossibleHistoriesRejectBothLoadAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory), valid = journal([.attempted, .planned])
        let invalid = [
            ComputerUseTextStepJournal(taskID: "task", promptDigest: "bad", contractDigest: valid.contractDigest, stepIDs: valid.stepIDs, statuses: valid.statuses),
            ComputerUseTextStepJournal(taskID: "task", promptDigest: valid.promptDigest, contractDigest: "bad", stepIDs: valid.stepIDs, statuses: valid.statuses),
            ComputerUseTextStepJournal(taskID: "task", promptDigest: valid.promptDigest, contractDigest: valid.contractDigest, stepIDs: ["same", "same"], statuses: valid.statuses),
            journal([.planned, .attempted]), journal([.uncertain, .verified]), journal([.attempted, .attempted]), journal([])]
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        for entry in invalid {
            let bytes = try JSONEncoder().encode(entry)
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try store.load(taskID: "task"))
            XCTAssertThrowsError(try store.save(entry, replacing: nil))
            XCTAssertThrowsError(try store.save(valid, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testJournalProbeDoesNotCreateStorageOrAcceptInvalidDirectoriesAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try ComputerUseTextStepStore(directory: directory)
        XCTAssertFalse(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))

        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: alias))
        let file = directory.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        XCTAssertThrowsError(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
    }

    func testAttemptedJournalSurvivesReopeningWithoutStoringText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ComputerUseTextStepJournal(taskID: "task", promptDigest: ComputerUseTextTaskContract.digest("prompt"),
            contractDigest: ComputerUseTextTaskContract.digest("contract"), stepIDs: ["step"], statuses: [.attempted])
        do { try ComputerUseTextStepStore(directory: directory).save(journal, replacing: nil) }
        XCTAssertTrue(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
        XCTAssertFalse(try ComputerUseTextStepStore.hasJournal(taskID: "another", directory: directory))
        let reopened = try ComputerUseTextStepStore(directory: directory)
        XCTAssertEqual(try reopened.load(taskID: "task"), journal)
        XCTAssertNil(try reopened.load(taskID: "another"))
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["taskID", "promptDigest", "contractDigest", "stepIDs", "statuses"])
    }

    func testCorruptExistingJournalCannotBecomeNewTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        try Data("invalid".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
        XCTAssertThrowsError(try store.load(taskID: "task"))
        XCTAssertThrowsError(try store.save(journal([.attempted, .planned]), replacing: nil))
    }

    func testSymlinkJournalIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertTrue(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
        XCTAssertThrowsError(try store.load(taskID: "task"))
        XCTAssertThrowsError(try store.save(journal([.attempted, .planned]), replacing: nil))
    }

    private func journal(_ statuses: [ComputerUseTaskStepStatus]) -> ComputerUseTextStepJournal {
        ComputerUseTextStepJournal(taskID: "task", promptDigest: ComputerUseTextTaskContract.digest("prompt"),
            contractDigest: ComputerUseTextTaskContract.digest("contract"), stepIDs: ["e\u{301}", "step-2"], statuses: statuses)
    }
}

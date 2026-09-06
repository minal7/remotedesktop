import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseTextStepStoreTests: XCTestCase {
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
        let journal = ComputerUseTextStepJournal(taskID: "task", promptDigest: "digest", contractDigest: "contract", stepIDs: ["step"], statuses: [.attempted])
        do { try ComputerUseTextStepStore(directory: directory).save(journal) }
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
    }

    func testSymlinkJournalIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertTrue(try ComputerUseTextStepStore.hasJournal(taskID: "task", directory: directory))
        XCTAssertThrowsError(try store.load(taskID: "task"))
    }
}

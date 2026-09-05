import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseTextStepStoreTests: XCTestCase {
    func testAttemptedJournalSurvivesReopeningWithoutStoringText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ComputerUseTextStepJournal(taskID: "task", promptDigest: "digest", contractDigest: "contract", stepIDs: ["step"], statuses: [.attempted])
        do { try ComputerUseTextStepStore(directory: directory).save(journal) }
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
        XCTAssertThrowsError(try store.load(taskID: "task"))
    }

    func testSymlinkJournalIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory)
        let file = directory.appendingPathComponent(ComputerUseTextTaskContract.digest("task") + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertThrowsError(try store.load(taskID: "task"))
    }
}

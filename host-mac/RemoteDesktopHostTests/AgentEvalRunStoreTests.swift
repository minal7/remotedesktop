#if DEBUG
import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalRunStoreTests: XCTestCase {
    func testUsesPrivateUniqueRunDirectoryAndEpisodePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEvalRunStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkdir(root.path, 0o700), 0)

        let first = try AgentEvalRunStore(taskID: "driver-task", rootPath: root.path)
        let second = try AgentEvalRunStore(taskID: "driver-task", rootPath: root.path)
        XCTAssertNotEqual(first.runID, second.runID)
        XCTAssertTrue(first.directory.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(first.episodePath.hasSuffix("/episodes/driver-task/episode.jsonl"))
        var info = stat()
        XCTAssertEqual(lstat(first.directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testRejectsNonprivateOrRelativeEvaluationRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEvalRunStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(mkdir(parent.path, 0o755), 0)
        XCTAssertThrowsError(try AgentEvalRunStore(taskID: "task", rootPath: parent.path))
        XCTAssertThrowsError(try AgentEvalRunStore(taskID: "task", rootPath: "relative/eval"))
    }
}
#endif

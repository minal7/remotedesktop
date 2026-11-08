#if DEBUG
import Darwin
import Foundation

struct AgentEvalRunStore {
    let taskID: String
    let runID: String
    let directory: URL

    init(taskID: String, rootPath: String) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 128,
              taskID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 95
              }), rootPath.hasPrefix("/"), !rootPath.contains("\0") else {
            throw AgentEvalWireError.invalidRequest
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.requirePrivateDirectory(root)
        let createdRunID = UUID().uuidString
        let runDirectory = root.appendingPathComponent(createdRunID, isDirectory: true)
        guard mkdir(runDirectory.path, 0o700) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        try Self.requirePrivateDirectory(runDirectory)
        self.taskID = taskID
        runID = createdRunID
        directory = runDirectory
    }

    var episodePath: String {
        directory.appendingPathComponent("episodes", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
            .appendingPathComponent("episode.jsonl").path
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw AgentEvalWireError.bootstrapFailure
        }
    }
}
#endif

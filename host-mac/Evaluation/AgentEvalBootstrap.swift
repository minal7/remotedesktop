#if DEBUG
import Darwin
import Foundation

struct AgentEvalBootstrap: Codable {
    let hostID: String
    let senderID: String
    let sessionID: String
    let pairingCode: String
    let port: UInt16
    let accessKey: String
}

struct AgentEvalBootstrapStore {
    let directory: URL
    private let file: URL

    init(baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let name = "RemoteDesktopHost-AgentEval-\(UUID().uuidString)"
        directory = baseDirectory.appendingPathComponent(name, isDirectory: true)
        file = directory.appendingPathComponent("bootstrap.json")
        guard mkdir(directory.path, 0o700) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else {
            try? FileManager.default.removeItem(at: directory)
            throw AgentEvalWireError.bootstrapFailure
        }
    }

    func write(_ bootstrap: AgentEvalBootstrap) throws {
        let data = try JSONEncoder().encode(bootstrap)
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentEvalWireError.bootstrapFailure }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw AgentEvalWireError.bootstrapFailure }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AgentEvalWireError.bootstrapFailure }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw AgentEvalWireError.bootstrapFailure }
    }

    func read() throws -> AgentEvalBootstrap {
        var info = stat()
        guard lstat(file.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600,
              let data = try? Data(contentsOf: file) else {
            throw AgentEvalWireError.bootstrapFailure
        }
        return try JSONDecoder().decode(AgentEvalBootstrap.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif

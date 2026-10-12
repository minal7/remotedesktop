import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class TrajectoryRecorder: AgentRecording {
    enum Failure: Error { case invalidDirectory, invalidEpisode, invalidScreenshot, duplicateStep, closed, writeFailed }
    let episodeID: String
    let directory: URL
    private let directoryFD: Int32
    private let streamFD: Int32
    private var finished = false
    private var recordedSteps = Set<Int>()

    init(root: URL = TrajectoryRecorder.defaultRoot, episodeID: String = UUID().uuidString,
         now: Date = Date()) throws {
        guard Self.safeID(episodeID) else { throw Failure.invalidEpisode }
        try Self.prepareRoot(root)
        try Self.prune(root: root, before: now.addingTimeInterval(-7 * 86_400))
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.invalidDirectory }
        defer { Darwin.close(parent) }
        guard mkdirat(parent, episodeID, 0o700) == 0 else { throw Failure.invalidEpisode }
        let folder = openat(parent, episodeID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.invalidDirectory }
        let stream = openat(folder, "episode.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard stream >= 0 else { Darwin.close(folder); throw Failure.writeFailed }
        self.episodeID = episodeID
        directory = root.appendingPathComponent(episodeID, isDirectory: true)
        directoryFD = folder; streamFD = stream
    }

    deinit { Darwin.close(streamFD); Darwin.close(directoryFD) }

    func record(_ step: AgentEpisodeStep) throws {
        guard !finished else { throw Failure.closed }
        guard step.episodeID == episodeID, step.step == step.observation.budget.step else { throw Failure.invalidEpisode }
        guard !recordedSteps.contains(step.step) else { throw Failure.duplicateStep }
        try step.validate()
        let png = try Self.decodePNG(step.observation.screenshot)
        let name = String(format: "step-%03d.png", step.step)
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        defer { Darwin.close(fd) }
        try Self.write(png, to: fd)
        guard fsync(fd) == 0 else { throw Failure.writeFailed }
        try append(.step(step))
        guard fsync(directoryFD) == 0 else { throw Failure.writeFailed }
        recordedSteps.insert(step.step)
    }

    func finish(_ footer: AgentEpisodeFooter) throws {
        guard !finished else { throw Failure.closed }
        guard footer.episodeID == episodeID else { throw Failure.invalidEpisode }
        try append(.footer(footer))
        finished = true
    }

    static func deleteHistory(root: URL = TrajectoryRecorder.defaultRoot) throws {
        try prepareRoot(root)
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard safeID(child.lastPathComponent) else { continue }
            var info = stat()
            guard lstat(child.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }

    private func append(_ record: AgentEpisodeRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(record)
        bytes.append(0x0a)
        try Self.write(bytes, to: streamFD)
        guard fsync(streamFD) == 0 else { throw Failure.writeFailed }
    }

    static func decodePNG(_ encoded: String) throws -> Data {
        guard let data = Data(base64Encoded: encoded),
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw Failure.invalidScreenshot }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func prepareRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.invalidDirectory }
    }

    private static func prune(root: URL, before cutoff: Date) throws {
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            guard safeID(child.lastPathComponent) else { continue }
            var info = stat()
            guard lstat(child.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            guard let created = try child.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteDesktopHost/episodes", isDirectory: true)
    }
}

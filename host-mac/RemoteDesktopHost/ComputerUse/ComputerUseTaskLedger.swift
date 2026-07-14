import Foundation

/// A small at-most-once ledger for privileged prompts. It is written before a
/// prompt starts, so an ambiguous CloudKit retry or host restart cannot execute
/// the same task ID twice. Terminal responses are retained for safe replay.
final class ComputerUseTaskLedger {
    enum Claim: Equatable {
        case new
        case accepted
        case completed(String)
    }

    private struct Record: Codable {
        let acceptedAt: Date
        var response: String?
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var records: [String: Record]

    init(
        fileURL: URL = ComputerUseTaskLedger.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func claim(taskID: String) throws -> Claim {
        if let existing = records[taskID] {
            return existing.response.map(Claim.completed) ?? .accepted
        }
        records[taskID] = Record(acceptedAt: Date(), response: nil)
        prune()
        try persist()
        return .new
    }

    func complete(taskID: String, response: String) {
        guard var record = records[taskID] else { return }
        record.response = String(response.prefix(4_000))
        records[taskID] = record
        try? persist()
    }

    private func prune() {
        let cutoff = Date(timeIntervalSinceNow: -(90 * 24 * 60 * 60))
        let accepted = records.filter { $0.value.response == nil }
        let completed = records
            .filter { $0.value.response != nil && $0.value.acceptedAt >= cutoff }
            .sorted { $0.value.acceptedAt > $1.value.acceptedAt }
        // Never evict an accepted-but-nonterminal privileged task: doing so
        // would permit a delayed retry to execute it again after a restart.
        // Completed records outlive CloudKit's one-hour delivery window by a
        // wide margin, while the generous cap keeps storage bounded.
        let completedCapacity = max(0, 10_000 - accepted.count)
        records = accepted
        for (key, value) in completed.prefix(completedCapacity) {
            records[key] = value
        }
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Tasks", isDirectory: true)
            .appendingPathComponent("processed-prompts.json")
    }
}

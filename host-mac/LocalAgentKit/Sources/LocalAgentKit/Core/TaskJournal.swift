import Foundation

/// One finished task as the journal keeps it. The request is redacted before it's ever
/// stored. Screenshots, typed text, page contents and answers are never part of a record.
public struct TaskRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var request: String
    public var seconds: Double = 0
    public var outcome = ""
    public var steps = 0
    public var jobs = 0
    public var compactions = 0
    public var apps: [String] = []
    public var sites: [String] = []
    public var models: [String] = []
    /// The person's own verdict, the one thing the harness can't measure.
    public var worked: Bool?

    public init(id: UUID = UUID(), startedAt: Date = Date(), request: String) {
        self.id = id
        self.startedAt = startedAt
        self.request = TaskJournal.redact(request)
    }

    /// The kind of ending only. A failure's own wording can quote the screen or typed text.
    static func outcomeName(_ outcome: HarnessOutcome) -> String {
        switch outcome {
        case let .completed(_, verified): return verified ? "completed" : "completed_unverified"
        case .failed: return "failed"
        case .handoff: return "handed_to_person"
        case .paused: return "paused"
        case .cancelled: return "cancelled"
        case .needsApproval: return "waiting_for_approval"
        case .needsAnswer: return "waiting_for_answer"
        }
    }
}

/// What people ask the agent to do and how it goes, kept so real use can become test
/// tasks. It lives only on this Mac and nothing here touches the network: a record reaches
/// anyone else only when the person reads a report and sends it themselves.
public final class TaskJournal: @unchecked Sendable {
    public static let retention: TimeInterval = 30 * 24 * 3_600
    public static let maximumRecords = 500

    private let file: URL
    private let lock = NSLock()

    public init(directory: URL) {
        file = directory.appendingPathComponent("task-journal.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func record(_ record: TaskRecord, now: Date = Date()) {
        lock.withLock {
            var all = load()
            if let index = all.firstIndex(where: { $0.id == record.id }) {
                // A paused task that resumes is still one task, and keeps its verdict.
                var merged = record
                merged.worked = all[index].worked
                all[index] = merged
            } else {
                all.append(record)
            }
            save(all, now: now)
        }
    }

    public func records() -> [TaskRecord] { lock.withLock { load() } }

    public func setFeedback(id: UUID, worked: Bool) {
        lock.withLock {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].worked = worked
            save(all, now: Date())
        }
    }

    public func delete(id: UUID) {
        lock.withLock { save(load().filter { $0.id != id }, now: Date()) }
    }

    public func deleteAll() {
        lock.withLock { _ = try? FileManager.default.removeItem(at: file) }
    }

    /// Exactly what would be shared, as readable text for the person to check, edit and
    /// send. Sites stay out unless asked for, since a list of them can say a lot about someone.
    public func report(ids: [UUID], includeSites: Bool = false) -> String {
        let chosen = lock.withLock { load() }.filter { ids.contains($0.id) }.map { record -> TaskRecord in
            var copy = record
            copy.request = Self.redact(record.request)
            if !includeSites { copy.sites = [] }
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(chosen)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func load() -> [TaskRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaskRecord].self, from: data)) ?? []
    }

    private func save(_ records: [TaskRecord], now: Date) {
        let kept = records.filter { now.timeIntervalSince($0.startedAt) < Self.retention }.suffix(Self.maximumRecords)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(kept)) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Redaction

    private static let rules: [(pattern: String, replacement: String)] = [
        // Order matters: secrets and addresses go before the number rule can split them.
        (#"(?i)\b(password|passcode|pin|otp|code|ssn|cvv|token|api key)\b(\s*(is|:|=)\s*|\s+)\S+"#, "$1 [secret]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        (#"(?i)\bhttps?://([A-Za-z0-9.-]+)[^\s]*"#, "$1"),
        (#"(?:~|/Users|/Volumes|/home)/[^\s,;]*"#, "[path]"),
        (#"(?i)\b\d{1,6}\s+(?:[A-Za-z]+\s){1,4}(?:street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|court|ct|way|place|pl)\b\.?"#, "[address]"),
        (#"\+?\d[\d\s().-]{6,}\d"#, "[number]"),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.replacement)
        }
        return result
    }

    /// The site without the page, which can hold names, searches and account numbers.
    public static func siteName(from address: String) -> String? {
        let text = address.contains("://") ? address : "https://" + address
        guard let host = URL(string: text)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

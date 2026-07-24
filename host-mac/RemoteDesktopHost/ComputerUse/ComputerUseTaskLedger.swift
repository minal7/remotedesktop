import Darwin
import Foundation

/// A small at-most-once ledger for privileged prompts. It is written before a
/// prompt starts, so an ambiguous CloudKit retry or host restart cannot execute
/// the same task ID twice. Terminal responses are retained for safe replay.
final class ComputerUseTaskLedger {
    enum Claim: Equatable {
        case new
        case accepted
        case paused(appliedControlRevision: UInt64)
        case completed(String)
        case identityMismatch
    }

    enum Control: String, Codable, Equatable {
        case pause
        case resume
        case cancel
    }

    enum ControlState: String, Codable, Equatable {
        case running
        case paused
        case cancelled
    }

    struct ControlResolution: Equatable {
        enum Disposition: Equatable {
            case advanced
            case duplicateOrStale
            case identityMismatch
        }

        let disposition: Disposition
        let state: ControlState?
        let appliedRevision: UInt64?
        let terminalResponse: String?
        let promptClaimed: Bool
    }

    enum LedgerError: Error, Equatable {
        case invalidIdentity
        case invalidControl
        case unavailable
    }

    struct TerminalResult: Equatable {
        let response: String
        let outcome: ComputerUseTerminalOutcome?
    }

    static let stoppedResponse = "Stopped. You're in control of the Mac."

    private struct ControlSnapshot: Codable {
        var revision: UInt64
        var state: ControlState
    }

    private struct Record: Codable {
        let acceptedAt: Date
        var senderID: String?
        var sessionID: String?
        var promptClaimed: Bool
        var executionStarted: Bool
        var response: String?
        var outcome: ComputerUseTerminalOutcome?
        var control: ControlSnapshot?

        init(
            acceptedAt: Date,
            senderID: String,
            sessionID: String,
            promptClaimed: Bool,
            executionStarted: Bool,
            response: String? = nil,
            outcome: ComputerUseTerminalOutcome? = nil,
            control: ControlSnapshot? = nil
        ) {
            self.acceptedAt = acceptedAt
            self.senderID = senderID
            self.sessionID = sessionID
            self.promptClaimed = promptClaimed
            self.executionStarted = executionStarted
            self.response = response
            self.outcome = outcome
            self.control = control
        }

        private enum CodingKeys: String, CodingKey {
            case acceptedAt
            case senderID
            case sessionID
            case promptClaimed
            case executionStarted
            case response
            case outcome
            case control
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            acceptedAt = try values.decode(Date.self, forKey: .acceptedAt)
            senderID = try values.decodeIfPresent(String.self, forKey: .senderID)
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            response = try values.decodeIfPresent(String.self, forKey: .response)
            if let rawOutcome = try values.decodeIfPresent(
                String.self,
                forKey: .outcome) {
                outcome = ComputerUseTerminalOutcome(rawValue: rawOutcome)
            } else {
                outcome = nil
            }
            control = try values.decodeIfPresent(
                ControlSnapshot.self,
                forKey: .control)
            // Records written before ordered controls existed were created
            // only by Prompt claims, and therefore conservatively represent
            // an execution that may already have started.
            promptClaimed = try values.decodeIfPresent(
                Bool.self,
                forKey: .promptClaimed) ?? true
            executionStarted = try values.decodeIfPresent(
                Bool.self,
                forKey: .executionStarted) ?? true
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var initializationError: LedgerError?
    private var records: [String: Record]

    init(
        fileURL: URL = ComputerUseTaskLedger.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(
                [String: Record].self,
                from: data)
            records = decoded
            initializationError = nil
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile {
            // A genuinely new ledger is the only condition that may start
            // from an empty set. Existing unreadable or malformed state could
            // contain an accepted privileged task and must poison the ledger
            // rather than make that task executable again.
            records = [:]
            initializationError = nil
        } catch {
            records = [:]
            initializationError = .unavailable
        }
    }

    func claim(
        taskID: String,
        senderID: String,
        sessionID: String
    ) throws -> Claim {
        try ensureAvailable()
        guard Self.validIdentity(
            taskID: taskID,
            senderID: senderID,
            sessionID: sessionID) else {
            throw LedgerError.invalidIdentity
        }

        guard var record = records[taskID] else {
            let record = Record(
                acceptedAt: Date(),
                senderID: senderID,
                sessionID: sessionID,
                promptClaimed: true,
                executionStarted: true)
            try commit(record, for: taskID)
            return .new
        }
        let wasUnbound = record.senderID == nil || record.sessionID == nil
        guard bindOrMatch(
            &record,
            senderID: senderID,
            sessionID: sessionID) else {
            return .identityMismatch
        }

        if let response = record.response {
            if !record.promptClaimed || wasUnbound {
                record.promptClaimed = true
                try commit(record, for: taskID)
            }
            return .completed(response)
        }

        if record.control?.state == .paused,
           !record.executionStarted {
            record.promptClaimed = true
            try commit(record, for: taskID)
            return .paused(
                appliedControlRevision: record.control?.revision ?? 0)
        }

        // Resume may arrive after a pre-Prompt Pause has already caused the
        // Prompt to be claimed. It remains safe to start exactly once because
        // the durable record proves no execution began while it was paused.
        if !record.executionStarted {
            record.promptClaimed = true
            record.executionStarted = true
            try commit(record, for: taskID)
            return .new
        }
        if wasUnbound {
            try commit(record, for: taskID)
        }
        return .accepted
    }

    func applyControl(
        _ control: Control,
        taskID: String,
        revision: UInt64,
        senderID: String,
        sessionID: String
    ) throws -> ControlResolution {
        try ensureAvailable()
        guard Self.validIdentity(
            taskID: taskID,
            senderID: senderID,
            sessionID: sessionID) else {
            throw LedgerError.invalidIdentity
        }
        guard revision > 0 else { throw LedgerError.invalidControl }

        var record = records[taskID] ?? Record(
            acceptedAt: Date(),
            senderID: senderID,
            sessionID: sessionID,
            promptClaimed: false,
            executionStarted: false)
        guard bindOrMatch(
            &record,
            senderID: senderID,
            sessionID: sessionID) else {
            return ControlResolution(
                disposition: .identityMismatch,
                state: nil,
                appliedRevision: nil,
                terminalResponse: nil,
                promptClaimed: record.promptClaimed)
        }

        if let applied = record.control, revision <= applied.revision {
            return ControlResolution(
                disposition: .duplicateOrStale,
                state: applied.state,
                appliedRevision: applied.revision,
                terminalResponse: record.response,
                promptClaimed: record.promptClaimed)
        }

        let reducedState: ControlState
        if record.control?.state == .cancelled {
            // Cancel is absorbing. A later Pause or Resume advances the
            // acknowledgement revision, but it can never resurrect the task.
            reducedState = .cancelled
        } else {
            switch control {
            case .pause: reducedState = .paused
            case .resume: reducedState = .running
            case .cancel: reducedState = .cancelled
            }
        }
        record.control = ControlSnapshot(
            revision: revision,
            state: reducedState)
        if reducedState == .cancelled, record.response == nil {
            // Persist the terminal result before the manager cancels any
            // active executor. A delayed completion can no longer overwrite
            // this absorbing user intent.
            record.response = Self.stoppedResponse
            record.outcome = .unableToComplete
        }
        try commit(record, for: taskID)
        return ControlResolution(
            disposition: .advanced,
            state: reducedState,
            appliedRevision: revision,
            terminalResponse: record.response,
            promptClaimed: record.promptClaimed)
    }

    @discardableResult
    func complete(
        taskID: String,
        response: String,
        outcome: ComputerUseTerminalOutcome? = nil
    ) throws -> TerminalResult {
        try ensureAvailable()
        guard var record = records[taskID] else {
            throw LedgerError.unavailable
        }
        // The first terminal result wins. In particular, an executor that
        // unwinds after a durable Cancel cannot replace the stopped response.
        if let existingResponse = record.response {
            return TerminalResult(
                response: existingResponse,
                outcome: record.outcome)
        }
        record.response = String(response.prefix(4_000))
        record.outcome = outcome
        try commit(record, for: taskID)
        return TerminalResult(
            response: record.response ?? "",
            outcome: record.outcome)
    }

    func terminalOutcome(taskID: String) -> ComputerUseTerminalOutcome? {
        guard initializationError == nil else { return nil }
        return records[taskID]?.outcome
    }

    func appliedControlRevision(taskID: String) -> UInt64? {
        // `records` advances only after `persist` succeeds, so this remains
        // the last revision the host can prove reached durable storage even
        // when a later terminal write poisons the ledger. Terminal fallback
        // replies must carry that committed revision or a client that already
        // received Resume would correctly reject them as stale.
        return records[taskID]?.control?.revision
    }

    private func ensureAvailable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func bindOrMatch(
        _ record: inout Record,
        senderID: String,
        sessionID: String
    ) -> Bool {
        if let boundSenderID = record.senderID,
           let boundSessionID = record.sessionID {
            return boundSenderID == senderID && boundSessionID == sessionID
        }
        // This is the one-time migration path for a pre-control ledger record.
        // Once bound, every future Prompt and control must present both values.
        record.senderID = senderID
        record.sessionID = sessionID
        return true
    }

    private static func validIdentity(
        taskID: String,
        senderID: String,
        sessionID: String
    ) -> Bool {
        !taskID.isEmpty && !senderID.isEmpty && !sessionID.isEmpty
    }

    private func commit(_ record: Record, for taskID: String) throws {
        var candidate = records
        candidate[taskID] = record
        prune(&candidate)
        do {
            try persist(candidate)
        } catch {
            // A failed atomic write leaves the caller unable to prove whether
            // the safety state reached durable storage. Poison this in-process
            // ledger so a later Prompt cannot execute merely because the disk
            // recovers before the unacknowledged Pause or Cancel is retried.
            initializationError = .unavailable
            throw error
        }
        records = candidate
    }

    private func prune(_ candidate: inout [String: Record]) {
        let cutoff = Date(timeIntervalSinceNow: -(90 * 24 * 60 * 60))
        let accepted = candidate.filter {
            $0.value.promptClaimed && $0.value.response == nil
        }
        let replayable = candidate
            .filter {
                (!$0.value.promptClaimed || $0.value.response != nil)
                    && $0.value.acceptedAt >= cutoff
            }
            .sorted { $0.value.acceptedAt > $1.value.acceptedAt }
        // Never evict an accepted-but-nonterminal privileged task: doing so
        // would permit a delayed retry to execute it again after a restart.
        // Terminal records and controls that arrived before their Prompt
        // outlive CloudKit's delivery window by a wide margin, while the
        // generous cap keeps storage bounded.
        let replayableCapacity = max(0, 10_000 - accepted.count)
        candidate = accepted
        for (key, value) in replayable.prefix(replayableCapacity) {
            candidate[key] = value
        }
    }

    private func persist(_ candidate: [String: Record]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(candidate).write(to: fileURL, options: .atomic)
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

/// Privacy-safe evidence for browser pointer effects that were actually
/// posted by the visual executor. This is deliberately separate from the
/// at-most-once task ledger: an unavailable evidence file must never make the
/// executor retry an input that may already have reached macOS.
struct ComputerUseBrowserActionGroundingDraft: Equatable, Sendable {
    let directive: String
    let rawNormalizedPoint: [Int]
    let preHostGroundingNormalizedPoint: [Int]
}

/// A bounded, owner-only attestation ledger used by local live acceptance.
/// It contains no prompt, target label, visible text, account identity, or
/// response. Records are appended only after `ComputerUseHostTools.perform`
/// returns successfully.
actor ComputerUseBrowserActionAttestationLedger {
    enum PlannerProvenance: String, Codable, Equatable, Sendable {
        case appleFoundationModels = "apple-foundation-models"
        case nonFoundation = "non-foundation"
        case mixed
    }

    enum LedgerError: Error, Equatable {
        case invalidRecord
        case unsafePath
        case malformedLedger
        case oversizedLedger
    }

    private struct Grounding: Codable, Equatable {
        let directive: String
        let rawNormalizedPoint: [Int]
        let preHostGroundingNormalizedPoint: [Int]
        let hostGroundingApplied: Bool
        let groundedScreenPoint: [Int]
        let effectPosted: Bool
    }

    private struct TaskRecord: Codable, Equatable {
        var plannerProvenance: PlannerProvenance
        var groundings: [Grounding]
        var updatedAt: Date
    }

    private struct Snapshot: Codable, Equatable {
        let version: Int
        var tasks: [String: TaskRecord]
    }

    static let version = 1
    static let maximumTasks = 10_000
    static let maximumGroundingsPerTask = 100
    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true)
        return base
            .appendingPathComponent(
                "Remote Desktop Host",
                isDirectory: true)
            .appendingPathComponent(
                "Computer Use Tasks",
                isDirectory: true)
            .appendingPathComponent(
                "browser-action-attestations.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var loadedSnapshot: Snapshot?

    init(
        fileURL: URL = ComputerUseBrowserActionAttestationLedger
            .defaultFileURL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    func recordPostedGrounding(
        taskID: String,
        plannerProvenance: PlannerProvenance,
        draft: ComputerUseBrowserActionGroundingDraft,
        groundedScreenPoint: [Int]
    ) throws {
        guard Self.validTaskID(taskID),
              Self.validDirective(draft.directive),
              Self.validNormalizedPoint(draft.rawNormalizedPoint),
              draft.preHostGroundingNormalizedPoint
                == draft.rawNormalizedPoint,
              Self.validScreenPoint(groundedScreenPoint) else {
            throw LedgerError.invalidRecord
        }

        var candidate = try loadSnapshotIfNeeded()
        let timestamp = now()
        var task = candidate.tasks[taskID] ?? TaskRecord(
            plannerProvenance: plannerProvenance,
            groundings: [],
            updatedAt: timestamp)
        if task.plannerProvenance != plannerProvenance {
            task.plannerProvenance = .mixed
        }
        task.groundings.append(Grounding(
            directive: draft.directive,
            rawNormalizedPoint: draft.rawNormalizedPoint,
            preHostGroundingNormalizedPoint:
                draft.preHostGroundingNormalizedPoint,
            hostGroundingApplied: true,
            groundedScreenPoint: groundedScreenPoint,
            effectPosted: true))
        if task.groundings.count > Self.maximumGroundingsPerTask {
            task.groundings.removeFirst(
                task.groundings.count - Self.maximumGroundingsPerTask)
        }
        task.updatedAt = timestamp
        candidate.tasks[taskID] = task
        prune(&candidate, now: timestamp)
        try persist(candidate)
        loadedSnapshot = candidate
    }

    private func loadSnapshotIfNeeded() throws -> Snapshot {
        if let loadedSnapshot { return loadedSnapshot }
        let snapshot = try withPinnedDirectory { directory in
            guard let data = try readExistingFile(directory: directory) else {
                return Snapshot(version: Self.version, tasks: [:])
            }
            guard data.count <= Self.maximumEncodedBytes else {
                throw LedgerError.oversizedLedger
            }
            let decoded: Snapshot
            do {
                decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            } catch {
                throw LedgerError.malformedLedger
            }
            guard decoded.version == Self.version,
                  decoded.tasks.count <= Self.maximumTasks,
                  decoded.tasks.allSatisfy({ taskID, task in
                      Self.validTaskID(taskID)
                        && task.groundings.count
                            <= Self.maximumGroundingsPerTask
                        && task.groundings.allSatisfy(Self.validGrounding)
                  }) else {
                throw LedgerError.malformedLedger
            }
            return decoded
        }
        loadedSnapshot = snapshot
        return snapshot
    }

    private func prune(_ snapshot: inout Snapshot, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        snapshot.tasks = snapshot.tasks.filter {
            $0.value.updatedAt >= cutoff
        }
        if snapshot.tasks.count > Self.maximumTasks {
            let retained = snapshot.tasks.sorted {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt > $1.value.updatedAt
                }
                return $0.key < $1.key
            }.prefix(Self.maximumTasks)
            snapshot.tasks = Dictionary(uniqueKeysWithValues: retained.map {
                ($0.key, $0.value)
            })
        }
    }

    private func persist(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumEncodedBytes else {
            throw LedgerError.oversizedLedger
        }
        try withPinnedDirectory { directory in
            try validateExistingDestination(directory: directory)
            let name = fileURL.lastPathComponent
            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let temporary = temporaryName.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            }
            guard temporary >= 0 else { throw Self.posixError() }
            var renamed = false
            defer {
                Darwin.close(temporary)
                if !renamed {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(directory, $0, 0)
                    }
                }
            }
            guard Darwin.fchmod(temporary, S_IRUSR | S_IWUSR) == 0 else {
                throw Self.posixError()
            }
            var temporaryStatus = stat()
            guard Darwin.fstat(temporary, &temporaryStatus) == 0,
                  temporaryStatus.st_mode & S_IFMT == S_IFREG,
                  temporaryStatus.st_uid == Darwin.geteuid(),
                  temporaryStatus.st_nlink == 1,
                  temporaryStatus.st_mode & mode_t(0o777)
                    == mode_t(0o600) else {
                throw LedgerError.unsafePath
            }
            try Self.writeAll(data, to: temporary)
            try Self.synchronize(temporary)
            let renameResult = temporaryName.withCString { source in
                name.withCString { destination in
                    Darwin.renameat(
                        directory,
                        source,
                        directory,
                        destination)
                }
            }
            guard renameResult == 0 else { throw Self.posixError() }
            renamed = true
            try Self.synchronize(directory)
            try validateExistingDestination(
                directory: directory,
                requireOwnerOnlyPermissions: true)
        }
    }

    private func withPinnedDirectory<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = directoryURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw LedgerError.unsafePath }
        defer { Darwin.close(directory) }
        guard Darwin.fchmod(directory, S_IRWXU) == 0 else {
            throw Self.posixError()
        }
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = directoryURL.path.withCString {
            Darwin.lstat($0, &pathStatus)
        }
        guard Darwin.fstat(directory, &descriptorStatus) == 0,
              pathResult == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_mode & mode_t(0o777)
                == mode_t(0o700) else {
            throw LedgerError.unsafePath
        }
        return try body(directory)
    }

    private func readExistingFile(directory: Int32) throws -> Data? {
        let name = fileURL.lastPathComponent
        var pathStatus = stat()
        let statusResult = name.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }
        guard Self.validRegularFile(pathStatus) else {
            throw LedgerError.unsafePath
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw LedgerError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              Self.validRegularFile(openedStatus),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LedgerError.unsafePath
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            guard count > 0 else { break }
            guard data.count + count <= Self.maximumEncodedBytes else {
                throw LedgerError.oversizedLedger
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func validateExistingDestination(
        directory: Int32,
        requireOwnerOnlyPermissions: Bool = false
    ) throws {
        let name = fileURL.lastPathComponent
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        guard Self.validRegularFile(status),
              !requireOwnerOnlyPermissions
                || status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw LedgerError.unsafePath
        }
    }

    private static func validGrounding(_ grounding: Grounding) -> Bool {
        validDirective(grounding.directive)
            && validNormalizedPoint(grounding.rawNormalizedPoint)
            && grounding.preHostGroundingNormalizedPoint
                == grounding.rawNormalizedPoint
            && grounding.hostGroundingApplied
            && validScreenPoint(grounding.groundedScreenPoint)
            && grounding.effectPosted
    }

    private static func validTaskID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                (48 ... 57).contains(scalar.value)
                    || (65 ... 90).contains(scalar.value)
                    || (97 ... 122).contains(scalar.value)
                    || [45, 46, 95].contains(scalar.value)
            }
    }

    private static func validDirective(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 32
            && value.unicodeScalars.allSatisfy { scalar in
                (97 ... 122).contains(scalar.value)
                    || scalar.value == 45
            }
    }

    private static func validNormalizedPoint(_ point: [Int]) -> Bool {
        point.count == 2 && point.allSatisfy { (0 ... 1_000).contains($0) }
    }

    private static func validScreenPoint(_ point: [Int]) -> Bool {
        point.count == 2
    }

    private static func validRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == Darwin.geteuid()
            && status.st_nlink == 1
            && status.st_size >= 0
            && status.st_size <= maximumEncodedBytes
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

#if DEBUG
import CryptoKit
import Darwin
import Foundation

struct AgentEvalFaraExchangeIdentity: Codable, Equatable, Sendable {
    let caseID: String
    let runToken: String
    let driverTaskID: String
    let runID: String

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case runToken = "run_token"
        case driverTaskID = "driver_task_id"
        case runID = "run_id"
    }
}

enum AgentEvalFaraExchangeActivation {
    static let allowedCases: [String: String] = {
        var cases: [String: String] = [
        "memory-recall-10-01": "/memory-seat.html",
        "memory-recall-10-02": "/memory-contact.html",
        "memory-recall-10-03": "/memory-address.html",
        "memory-recall-10-04": "/memory-airport.html",
        "memory-recall-10-05": "/memory-greeting.html",
        "memory-recall-10-06": "/memory-seat-active.html",
        "memory-recall-10-07": "/memory-phone.html",
        "memory-recall-10-08": "/memory-seat-unavailable.html",
        "memory-recall-10-09": "/memory-seat-updated.html",
        "memory-recall-10-10": "/memory-name-style.html",
        "memory-privacy-10-01": "/memory-greeting.html",
        "memory-privacy-10-02": "/memory-greeting.html",
        "memory-privacy-10-03": "/memory-contact.html",
        "memory-privacy-10-04": "/memory-address.html",
        "memory-privacy-10-05": "/memory-privacy-10-05.html",
        "memory-privacy-10-06": "/memory-greeting.html",
        "memory-privacy-10-07": "/memory-contact.html",
        "memory-privacy-10-08": "/memory-privacy-10-08.html",
        "memory-privacy-10-09": "/memory-privacy-10-09.html",
        ]
        for index in 1...10 {
            let identifier = String(format: "memory-injection-10-%02d", index)
            cases[identifier] = "/\(identifier).html"
        }
        return cases
    }()
    static var allowedCaseIDs: Set<String> { Set(allowedCases.keys) }

    static func isValid(caseID: String, runToken: String, driverTaskID: String,
                        policy: String, startURL: String,
                        environment: [String: String]) -> Bool {
        guard allowedCaseIDs.contains(caseID), policy == "fara15-4b",
              caseID == environment["EVAL_TASK_ID"],
              runToken == environment["EVAL_RUN_TOKEN"],
              runToken.utf8.count == 32,
              runToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let taskUUID = UUID(uuidString: driverTaskID),
              taskUUID.uuidString.lowercased() == driverTaskID,
              let components = URLComponents(string: startURL),
              components.scheme == "http", components.host == "127.0.0.1",
              components.port == 8765, components.path == allowedCases[caseID],
              components.user == nil, components.password == nil,
              components.fragment == nil else { return false }
        let tokens = components.queryItems?.filter { $0.name == "__eval_run" } ?? []
        return tokens.count == 1 && tokens[0].value == runToken
    }
}

struct AgentEvalFaraExchangeReceipt: Codable, Equatable, Sendable {
    struct Artifact: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let byteCount: Int

        enum CodingKeys: String, CodingKey {
            case path, sha256
            case byteCount = "byte_count"
        }
    }

    struct Sink: Codable, Equatable, Sendable {
        let status: String
        let reasonCode: String?
        let artifacts: [Artifact]

        enum CodingKeys: String, CodingKey {
            case status, artifacts
            case reasonCode = "reason_code"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encode(reasonCode, forKey: .reasonCode)
            try container.encode(artifacts, forKey: .artifacts)
        }
    }

    let schemaVersion: Int
    let producerID: String
    let captureScope: String
    let coverageStatus: String
    let identity: AgentEvalFaraExchangeIdentity
    let successfulExchangeCount: Int
    let captureFailureCount: Int
    let sinks: [String: Sink]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case producerID = "producer_id"
        case captureScope = "capture_scope"
        case coverageStatus = "coverage_status"
        case identity
        case successfulExchangeCount = "successful_exchange_count"
        case captureFailureCount = "capture_failure_count"
        case sinks
    }
}

struct AgentEvalFaraLifecycleReceipt: Codable, Equatable, Sendable {
    struct Artifact: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let byteCount: Int
        enum CodingKeys: String, CodingKey { case path, sha256; case byteCount = "byte_count" }
    }
    struct Attempt: Codable, Equatable, Sendable {
        let index: Int
        let requestID: String
        let kind: String
        let outcome: String
        let request: Artifact?
        let response: Artifact?
        let responseComplete: Bool
        enum CodingKeys: String, CodingKey {
            case index, kind, outcome, request, response
            case requestID = "request_id"
            case responseComplete = "response_complete"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(kind, forKey: .kind)
            try c.encode(outcome, forKey: .outcome)
            if let request { try c.encode(request, forKey: .request) } else { try c.encodeNil(forKey: .request) }
            if let response { try c.encode(response, forKey: .response) } else { try c.encodeNil(forKey: .response) }
            try c.encode(responseComplete, forKey: .responseComplete)
        }
    }
    let schemaVersion: Int
    let producerID: String
    let captureScope: String
    let coverageStatus: String
    let identity: AgentEvalFaraExchangeIdentity
    let attemptCount: Int
    let captureFailureCount: Int
    let overflowed: Bool
    let attempts: [Attempt]
    enum CodingKeys: String, CodingKey {
        case identity, attempts, overflowed
        case schemaVersion = "schema_version"
        case producerID = "producer_id"
        case captureScope = "capture_scope"
        case coverageStatus = "coverage_status"
        case attemptCount = "attempt_count"
        case captureFailureCount = "capture_failure_count"
    }
}

/// Captures only completed Fara HTTP request/response bodies for one validated
/// Debug evaluation task. It never observes headers or ordinary app requests.
final class AgentEvalFaraExchangeEvidence: @unchecked Sendable {
    enum Failure: Error { case invalidIdentity, invalidDirectory, closed, receiptWriteFailed }

    static let maximumExchanges = 40
    static let maximumLifecycleAttempts = 160
    static let maximumBodyBytes = 8 * 1_024 * 1_024
    static let maximumTotalBytes = 128 * 1_024 * 1_024
    static let receiptName = "receipt.json"

    let identity: AgentEvalFaraExchangeIdentity
    private let directoryFD: Int32
    private let lock = NSLock()
    private var callbackCount = 0
    private var overflowSentinelRecorded = false
    private var successfulCount = 0
    private var failureCount = 0
    private var totalBytes = 0
    private var failed = false
    private var finished = false
    private var artifacts: [String: [AgentEvalFaraExchangeReceipt.Artifact]] = [
        "model_prompt": [], "model_action": [],
    ]
    private struct PendingAttempt {
        var value: AgentEvalFaraLifecycleReceipt.Attempt
        var terminal = false
    }
    private var lifecycleAttempts: [PendingAttempt] = []
    private var lifecycleIndexes: [UUID: Int] = [:]
    private var lifecycleFailures = 0
    private var lifecycleOverflowed = false
    private var lifecycleBytes = 0

    init(runDirectory: URL, driverTaskID: String, runID: String,
         caseID: String, runToken: String,
         environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard AgentEvalFaraExchangeActivation.allowedCaseIDs.contains(caseID),
              Self.validID(runToken), Self.validToken(runToken),
              let driverUUID = UUID(uuidString: driverTaskID), driverUUID.uuidString.lowercased() == driverTaskID,
              let guestRunUUID = UUID(uuidString: runID), guestRunUUID.uuidString == runID,
              environment["EVAL_TASK_ID"] == caseID,
              environment["EVAL_RUN_TOKEN"] == runToken else {
            throw Failure.invalidIdentity
        }
        identity = .init(caseID: caseID, runToken: runToken,
            driverTaskID: driverTaskID, runID: runID)
        let runFD = Self.openDirectoryWithoutSymlinks(runDirectory)
        guard runFD >= 0 else { throw Failure.invalidDirectory }
        defer { close(runFD) }
        var metadata = stat()
        guard fstat(runFD, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700,
              mkdirat(runFD, "evidence", 0o700) == 0 else {
            throw Failure.invalidDirectory
        }
        let evidenceFD = openat(runFD, "evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard evidenceFD >= 0 else { throw Failure.invalidDirectory }
        defer { close(evidenceFD) }
        guard fchmod(evidenceFD, 0o700) == 0,
              fstat(evidenceFD, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700,
              mkdirat(evidenceFD, "fara-exchange", 0o700) == 0 else {
            throw Failure.invalidDirectory
        }
        let fd = openat(evidenceFD, "fara-exchange", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        guard fchmod(fd, 0o700) == 0,
              fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw Failure.invalidDirectory
        }
        directoryFD = fd
    }

    /// Creates a fresh per-run directory under the host's private eval root.
    /// The run ID comes from the guest's already-created run store and is
    /// accepted only once by the capture session.
    convenience init(runRoot: URL, driverTaskID: String, runID: String,
                     caseID: String, runToken: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let parsedRunID = UUID(uuidString: runID), parsedRunID.uuidString == runID else {
            throw Failure.invalidIdentity
        }
        let rootFD = Self.openDirectoryWithoutSymlinks(runRoot)
        guard rootFD >= 0 else { throw Failure.invalidDirectory }
        defer { close(rootFD) }
        var metadata = stat()
        guard fstat(rootFD, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700 else {
            throw Failure.invalidDirectory
        }
        let directoryName = runID
        guard mkdirat(rootFD, directoryName, 0o700) == 0 else { throw Failure.invalidDirectory }
        let runDirectory = URL(fileURLWithPath: runRoot.path + "/" + directoryName, isDirectory: true)
        try self.init(runDirectory: runDirectory, driverTaskID: driverTaskID, runID: runID,
            caseID: caseID, runToken: runToken, environment: environment)
    }

    deinit { close(directoryFD) }

    func record(_ requestBody: Data, _ responseBody: Data) {
        lock.withLock {
            guard !finished else { return }
            let index = callbackCount
            if index >= Self.maximumExchanges {
                failed = true
                if !overflowSentinelRecorded {
                    failureCount += 1
                    overflowSentinelRecorded = true
                }
                return
            }
            callbackCount += 1
            guard !requestBody.isEmpty, !responseBody.isEmpty,
                  requestBody.count <= Self.maximumBodyBytes,
                  responseBody.count <= Self.maximumBodyBytes else {
                recordFailure()
                return
            }
            let pairBytes = requestBody.count + responseBody.count
            guard pairBytes <= Self.maximumTotalBytes,
                  totalBytes <= Self.maximumTotalBytes - pairBytes else {
                recordFailure()
                return
            }
            let name = String(format: "%03d", index)
            var requestArtifact: AgentEvalFaraExchangeReceipt.Artifact?
            do {
                requestArtifact = try Self.writeArtifact(requestBody, name: "\(name).request.body",
                    directoryFD: directoryFD)
                let responseArtifact = try Self.writeArtifact(responseBody, name: "\(name).response.body",
                    directoryFD: directoryFD)
                guard let requestArtifact else { throw Failure.invalidDirectory }
                artifacts["model_prompt", default: []].append(requestArtifact)
                artifacts["model_action", default: []].append(responseArtifact)
                successfulCount += 1
                totalBytes += pairBytes
            } catch {
                if requestArtifact != nil { _ = unlinkat(directoryFD, "\(name).request.body", 0) }
                recordFailure()
            }
        }
    }

    private func recordFailure() {
        failed = true
        if successfulCount + failureCount < Self.maximumExchanges { failureCount += 1 }
    }

    func beginLifecycleAttempt(id: UUID, kind: OSAtlasLlamaHTTPRequestKind, body: Data) {
        lock.withLock {
            guard !finished else { lifecycleFailure(); return }
            guard lifecycleIndexes[id] == nil else { lifecycleFailure(); return }
            guard lifecycleAttempts.count < Self.maximumLifecycleAttempts else {
                if !lifecycleOverflowed { lifecycleOverflowed = true; lifecycleFailure() }
                return
            }
            let index = lifecycleAttempts.count
            var artifact: AgentEvalFaraLifecycleReceipt.Artifact?
            do {
                guard body.count <= Self.maximumBodyBytes,
                      lifecycleBytes <= Self.maximumTotalBytes - body.count else {
                    throw Failure.invalidDirectory
                }
                artifact = try Self.writeLifecycleArtifact(body, name: String(format: "%03d.request.body", index),
                    directoryFD: directoryFD)
                lifecycleBytes += body.count
            } catch { lifecycleFailure() }
            let attempt = AgentEvalFaraLifecycleReceipt.Attempt(index: index,
                requestID: id.uuidString.lowercased(), kind: kind.rawValue, outcome: "pending",
                request: artifact, response: nil, responseComplete: false)
            lifecycleAttempts.append(PendingAttempt(value: attempt))
            lifecycleIndexes[id] = index
        }
    }

    func noteLifecycleFailure() { lock.withLock { lifecycleFailure() } }

    func finishLifecycleAttempt(id: UUID, outcome: OSAtlasLlamaHTTPOutcome,
                                responseBody: Data?, responseComplete: Bool) {
        lock.withLock {
            guard !finished, let index = lifecycleIndexes[id], lifecycleAttempts.indices.contains(index),
                  !lifecycleAttempts[index].terminal else { lifecycleFailure(); return }
            var attempt = lifecycleAttempts[index].value
            var responseArtifact: AgentEvalFaraLifecycleReceipt.Artifact?
            if let responseBody {
                do {
                    guard responseBody.count <= Self.maximumBodyBytes,
                          lifecycleBytes <= Self.maximumTotalBytes - responseBody.count else {
                        throw Failure.invalidDirectory
                    }
                    responseArtifact = try Self.writeLifecycleArtifact(responseBody,
                        name: String(format: "%03d.response.body", index), directoryFD: directoryFD)
                    lifecycleBytes += responseBody.count
                } catch { lifecycleFailure() }
            }
            if attempt.request == nil { lifecycleFailure() }
            if outcome == .completed && responseArtifact == nil { lifecycleFailure() }
            attempt = .init(index: attempt.index, requestID: attempt.requestID, kind: attempt.kind,
                outcome: outcome.rawValue, request: attempt.request, response: responseArtifact,
                responseComplete: outcome == .completed && responseComplete)
            lifecycleAttempts[index] = PendingAttempt(value: attempt, terminal: true)
        }
    }

    private func lifecycleFailure() {
        lifecycleFailures = min(Self.maximumLifecycleAttempts + 1, lifecycleFailures + 1)
    }

    func finishLifecycle() throws -> AgentEvalFaraLifecycleReceipt {
        try lock.withLock {
            guard !finished else { throw Failure.closed }
            finished = true
            let receipt = AgentEvalFaraLifecycleReceipt(schemaVersion: 2,
                producerID: "fara_http_lifecycle", captureScope: "dispatched_model_http_attempts",
                coverageStatus: "incomplete", identity: identity,
                attemptCount: lifecycleAttempts.count, captureFailureCount: lifecycleFailures,
                overflowed: lifecycleOverflowed, attempts: lifecycleAttempts.map(\.value))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(receipt)
            let fd = openat(directoryFD, Self.receiptName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.receiptWriteFailed }
            defer { close(fd) }
            do {
                guard fchmod(fd, 0o600) == 0 else { throw Failure.receiptWriteFailed }
                try Self.write(data, to: fd)
                guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw Failure.receiptWriteFailed }
            } catch {
                _ = unlinkat(directoryFD, Self.receiptName, 0)
                throw Failure.receiptWriteFailed
            }
            return receipt
        }
    }

    @discardableResult
    func finish() throws -> AgentEvalFaraExchangeReceipt {
        try lock.withLock {
            guard !finished else { throw Failure.closed }
            finished = true
            let prompt = sink("model_prompt")
            let action = sink("model_action")
            let unobserved = AgentEvalFaraExchangeReceipt.Sink(
                status: "unobserved", reasonCode: "callback_after_success_only", artifacts: [])
            let receipt = AgentEvalFaraExchangeReceipt(schemaVersion: 1,
                producerID: "fara_http_success",
                captureScope: "successful_completed_http_exchanges_only",
                coverageStatus: "incomplete", identity: identity,
                successfulExchangeCount: successfulCount,
                captureFailureCount: failureCount,
                sinks: ["model_prompt": prompt, "model_action": action,
                    "failed_or_cancelled_exchanges": unobserved])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(receipt)
            let fd = openat(directoryFD, Self.receiptName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.receiptWriteFailed }
            defer { close(fd) }
            do {
                guard fchmod(fd, 0o600) == 0 else { throw Failure.receiptWriteFailed }
                try Self.write(data, to: fd)
                guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw Failure.receiptWriteFailed }
            } catch {
                _ = unlinkat(directoryFD, Self.receiptName, 0)
                throw Failure.receiptWriteFailed
            }
            return receipt
        }
    }

    private func sink(_ id: String) -> AgentEvalFaraExchangeReceipt.Sink {
        let values = artifacts[id, default: []]
        return .init(status: failed ? "capture_failed" : (values.isEmpty ? "missing" : "captured"),
            reasonCode: failed ? "bounded_capture_failed" : (values.isEmpty ? "no_successful_exchange" : nil),
            artifacts: values)
    }

    private static func writeArtifact(_ data: Data, name: String,
                                      directoryFD: Int32) throws -> AgentEvalFaraExchangeReceipt.Artifact {
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.invalidDirectory }
        var complete = false
        defer {
            close(fd)
            if !complete { _ = unlinkat(directoryFD, name, 0) }
        }
        guard fchmod(fd, 0o600) == 0 else { throw Failure.invalidDirectory }
        try write(data, to: fd)
        guard fsync(fd) == 0 else { throw Failure.invalidDirectory }
        complete = true
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(path: "evidence/fara-exchange/\(name)", sha256: digest, byteCount: data.count)
    }

    private static func writeLifecycleArtifact(_ data: Data, name: String,
                                               directoryFD: Int32) throws -> AgentEvalFaraLifecycleReceipt.Artifact {
        let artifact = try writeArtifact(data, name: name, directoryFD: directoryFD)
        return .init(path: artifact.path, sha256: artifact.sha256, byteCount: artifact.byteCount)
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalidDirectory }
                offset += count
            }
        }
    }

    private static func openDirectoryWithoutSymlinks(_ url: URL) -> Int32 {
        guard url.isFileURL else { return -1 }
        // Keep the caller's physical path. Foundation may rewrite /private/var
        // to /var, which traverses a symlink and defeats the no-follow walk.
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return -1 }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return -1 }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { return -1 }
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(current)
            guard next >= 0 else { return -1 }
            current = next
        }
        return current
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Pins one guest run ID to the helper's explicit fixture identity, and routes
/// only the runtime's completed HTTP callback into the existing collector.
final class AgentEvalFaraExchangeCapture: @unchecked Sendable {
    enum Failure: Error { case invalidIdentity, missingRunID, mismatchedRunID, closed }

    private let configuration: EvalFaraHostExchangeCaptureConfiguration
    private let environment: [String: String]
    private let lifecycleEnabled: Bool
    private let lock = NSLock()
    private var pinnedRunID: UUID?
    private var collector: AgentEvalFaraExchangeEvidence?
    private var observedIDs: Set<UUID> = []
    private var acceptingExchange = false
    private var finished = false

    init(configuration: EvalFaraHostExchangeCaptureConfiguration,
         lifecycleEnabled: Bool = false,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.configuration = configuration
        self.lifecycleEnabled = lifecycleEnabled
        self.environment = environment
    }

    /// Binds lifecycle capture to an AgentEvalRunStore directory that already
    /// exists, keeping Fara evidence beside the run's other artifacts.
    convenience init(runDirectory: URL, configuration: EvalFaraHostExchangeCaptureConfiguration,
                     runID: UUID,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let expectedDirectory = URL(fileURLWithPath: configuration.runRoot, isDirectory: true)
            .standardizedFileURL.appendingPathComponent(runID.uuidString, isDirectory: true)
        guard runDirectory.standardizedFileURL == expectedDirectory else { throw Failure.invalidIdentity }
        self.init(configuration: configuration, lifecycleEnabled: true, environment: environment)
        let created = try AgentEvalFaraExchangeEvidence(runDirectory: runDirectory,
            driverTaskID: configuration.driverTaskID, runID: runID.uuidString,
            caseID: configuration.caseID, runToken: configuration.runToken,
            environment: environment)
        lock.withLock {
            collector = created
            pinnedRunID = runID
        }
    }

    /// A missing ID is permitted only before the guest's task run has bound;
    /// this excludes the helper's readiness warmup without inventing an ID.
    @discardableResult
    func beginRequest(runID: UUID?) throws -> Bool {
        try lock.withLock {
            guard !finished else { throw Failure.closed }
            guard let runID else {
                guard pinnedRunID == nil else { throw Failure.missingRunID }
                acceptingExchange = false
                return false
            }
            guard let canonical = UUID(uuidString: runID.uuidString), canonical == runID else {
                throw Failure.invalidIdentity
            }
            if let pinnedRunID {
                guard pinnedRunID == runID else { throw Failure.mismatchedRunID }
            } else {
                let created = try AgentEvalFaraExchangeEvidence(runRoot:
                    URL(fileURLWithPath: configuration.runRoot, isDirectory: true),
                    driverTaskID: configuration.driverTaskID, runID: runID.uuidString,
                    caseID: configuration.caseID, runToken: configuration.runToken,
                    environment: environment)
                collector = created
                pinnedRunID = runID
            }
            acceptingExchange = true
            return true
        }
    }

    func endRequest() { lock.withLock { acceptingExchange = false } }

    func record(_ requestBody: Data, _ responseBody: Data) {
        let target = lock.withLock { acceptingExchange ? collector : nil }
        target?.record(requestBody, responseBody)
    }

    func willDispatch(id: UUID, kind: OSAtlasLlamaHTTPRequestKind, body: Data) {
        guard lifecycleEnabled else { return }
        let result = lock.withLock { () -> (AgentEvalFaraExchangeEvidence?, Bool) in
            guard acceptingExchange, !finished else { return (nil, false) }
            guard observedIDs.insert(id).inserted else { return (collector, true) }
            if observedIDs.count > AgentEvalFaraExchangeEvidence.maximumLifecycleAttempts {
                observedIDs.remove(id)
                return (collector, true)
            }
            return (collector, false)
        }
        if result.1 { result.0?.noteLifecycleFailure() }
        else { result.0?.beginLifecycleAttempt(id: id, kind: kind, body: body) }
    }

    func didReadResponsePrefix(id: UUID, byteCount: Int) {
        guard lifecycleEnabled else { return }
        let target = lock.withLock { observedIDs.contains(id) ? collector : nil }
        if target == nil { lock.withLock { if acceptingExchange { collector?.noteLifecycleFailure() } } }
    }

    func didFinish(id: UUID, outcome: OSAtlasLlamaHTTPOutcome,
                   responseBody: Data?, responseComplete: Bool) {
        guard lifecycleEnabled else { return }
        let result = lock.withLock { () -> (AgentEvalFaraExchangeEvidence?, Bool) in
            guard observedIDs.remove(id) != nil else { return (acceptingExchange ? collector : nil, false) }
            return (collector, true)
        }
        guard let target = result.0 else { return }
        guard result.1 else { target.noteLifecycleFailure(); return }
        target.finishLifecycleAttempt(id: id, outcome: outcome,
            responseBody: responseBody, responseComplete: responseComplete)
    }

    @discardableResult
    func finish() throws -> AgentEvalFaraExchangeReceipt? {
        let target = lock.withLock { () -> AgentEvalFaraExchangeEvidence? in
            guard !finished else { return nil }
            finished = true
            acceptingExchange = false
            return collector
        }
        guard let target else { return nil }
        if lifecycleEnabled {
            _ = try target.finishLifecycle()
            return nil
        }
        return try target.finish()
    }
}

extension AgentEvalFaraExchangeCapture: OSAtlasLlamaHTTPRequestObserver {}
#endif

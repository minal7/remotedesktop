#if DEBUG
import CoreFoundation
import Darwin
import Foundation

struct AgentEvalOperatorApprovalTarget: Encodable {
    let id: Int
    let role: String
    let name: String
    let state: [String]
    let bbox: AgentBoundingBox
    let inView: Bool

    init(_ element: AgentElement) {
        id = element.id; role = element.role; name = element.name
        state = element.state; bbox = element.bbox; inView = element.inView
    }
}

struct AgentEvalOperatorApprovalTicket: Encodable {
    let version = 1
    let runID: String
    let caseID: String
    let taskID: String
    let requestID: String
    let responseFile: String
    let controlRevision: UInt64
    let hostControlEpoch: UInt64
    let fingerprint: String
    let scopeIdentity: String
    let approvalPurpose: String
    let riskTier: String
    let action: AgentAction
    let targets: [AgentEvalOperatorApprovalTarget]
    let contextBinding: String?
    let contextRevision: String?
    let contextDigest: String?

    var requestFilename: String { "operator-approval-\(requestID).request.json" }
    var responseFilename: String { "operator-approval-\(requestID).response.json" }
    var decisionFilename: String { "operator-approval-\(requestID).decision.json" }

    enum CodingKeys: String, CodingKey {
        case version, runID = "run_id", caseID = "case_id", taskID = "task_id"
        case requestID = "request_id", responseFile = "response_file", controlRevision = "control_revision"
        case hostControlEpoch = "host_control_epoch", fingerprint, scopeIdentity = "scope_identity"
        case approvalPurpose = "approval_purpose", riskTier = "risk_tier", action, targets
        case contextBinding = "context_binding", contextRevision = "context_revision"
        case contextDigest = "context_sha256"
    }
}

struct AgentEvalOperatorApprovalDecision {
    let approved: Bool
    let runID: String
    let caseID: String
    let taskID: String
    let requestID: String
    let controlRevision: UInt64
    let hostControlEpoch: UInt64
    let fingerprint: String
    let scopeIdentity: String
    let approvalPurpose: String
    let riskTier: String
    let contextBinding: String?
    let contextRevision: String?
    let contextDigest: String?

    func matches(_ ticket: AgentEvalOperatorApprovalTicket) -> Bool {
        runID == ticket.runID && caseID == ticket.caseID && taskID == ticket.taskID
            && requestID == ticket.requestID && controlRevision == ticket.controlRevision
            && hostControlEpoch == ticket.hostControlEpoch && fingerprint == ticket.fingerprint
            && scopeIdentity == ticket.scopeIdentity && approvalPurpose == ticket.approvalPurpose
            && riskTier == ticket.riskTier && contextBinding == ticket.contextBinding
            && contextRevision == ticket.contextRevision && contextDigest == ticket.contextDigest
    }

    static func decodeStrict(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "run_id", "case_id", "task_id", "request_id",
                  "control_revision", "host_control_epoch", "fingerprint", "scope_identity", "approval_purpose", "risk_tier",
                  "context_binding", "context_revision", "context_sha256", "approved"],
              Self.uint64(object["version"]) == 1,
              let approved = object["approved"] as? NSNumber,
              CFGetTypeID(approved) == CFBooleanGetTypeID(),
              let runID = object["run_id"] as? String, let caseID = object["case_id"] as? String,
              let taskID = object["task_id"] as? String, let requestID = object["request_id"] as? String,
              let revision = Self.uint64(object["control_revision"]),
              let epoch = Self.uint64(object["host_control_epoch"]),
              let fingerprint = object["fingerprint"] as? String,
              let scopeIdentity = object["scope_identity"] as? String,
              let purpose = object["approval_purpose"] as? String,
              let riskTier = object["risk_tier"] as? String,
              let binding = Self.optionalString(object["context_binding"]),
              let contextRevision = Self.optionalString(object["context_revision"]),
              let contextDigest = Self.optionalString(object["context_sha256"]) else { return nil }
        return Self(approved: approved.boolValue, runID: runID, caseID: caseID,
            taskID: taskID, requestID: requestID, controlRevision: revision,
            hostControlEpoch: epoch, fingerprint: fingerprint, scopeIdentity: scopeIdentity,
            approvalPurpose: purpose, riskTier: riskTier,
            contextBinding: binding, contextRevision: contextRevision, contextDigest: contextDigest)
    }

    private static func optionalString(_ value: Any?) -> String?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        guard let string = value as? String else { return nil }
        return .some(string)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue < 18_446_744_073_709_551_616.0 else { return nil }
        return number.uint64Value
    }
}

struct AgentEvalOperatorApprovalMailbox {
    private enum MailboxError: Error { case absent, invalid }
    enum ReadResult { case absent, invalid, decision(AgentEvalOperatorApprovalDecision) }
    let directory: URL
    let ticket: AgentEvalOperatorApprovalTicket

    func writeTicket() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writeExclusive(encoder.encode(ticket), to: directory.appendingPathComponent(ticket.requestFilename))
    }

    func consumeDecision() -> ReadResult {
        let url = directory.appendingPathComponent(ticket.responseFilename)
        let data: Data
        do { data = try readPrivateFile(url) }
        catch MailboxError.absent { return .absent }
        catch { return .invalid }
        guard let decision = AgentEvalOperatorApprovalDecision.decodeStrict(data), decision.matches(ticket) else {
            return .invalid
        }
        do {
            try writeExclusive(data, to: directory.appendingPathComponent(ticket.decisionFilename))
            guard unlink(url.path) == 0 else { return .invalid }
        } catch { return .invalid }
        return .decision(decision)
    }

    private func writeExclusive(_ data: Data, to destination: URL) throws {
        try requirePrivateDirectory()
        let temporary = directory.appendingPathComponent(".operator-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AgentEvalWireError.bootstrapFailure }
        var closeFD = true
        defer { if closeFD { close(fd) }; unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw AgentEvalWireError.invalidRequest }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw AgentEvalWireError.bootstrapFailure }
                offset += written
            }
        }
        guard fsync(fd) == 0, close(fd) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        closeFD = false
        guard link(temporary.path, destination.path) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        guard unlink(temporary.path) == 0 else { throw AgentEvalWireError.bootstrapFailure }
    }

    private func readPrivateFile(_ url: URL) throws -> Data {
        try requirePrivateDirectory()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? MailboxError.absent : MailboxError.invalid }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 16_384 else { throw MailboxError.invalid }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let amount = read(fd, base.advanced(by: offset), raw.count - offset)
                guard amount > 0 else { break }
                offset += amount
            }
            return offset
        }
        guard count == data.count else { throw MailboxError.invalid }
        return data
    }

    private func requirePrivateDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw AgentEvalWireError.bootstrapFailure
        }
    }
}

#endif

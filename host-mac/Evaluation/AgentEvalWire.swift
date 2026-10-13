#if DEBUG
import Foundation

struct AgentEvalRequest: Decodable {
    struct Start: Decodable {
        let url: String?
        let app: String?

        private enum CodingKeys: String, CodingKey { case url, app }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let keys = Set(container.allKeys)
            guard keys.count == 1 else { throw AgentEvalWireError.invalidRequest }
            url = try container.decodeIfPresent(String.self, forKey: .url)
            app = try container.decodeIfPresent(String.self, forKey: .app)
            guard (url != nil) != (app != nil) else { throw AgentEvalWireError.invalidRequest }
        }
    }

    struct ApprovalPolicy: Decodable {
        let allowFixtureCommit: Bool
        let allowFixtureInteraction: Bool
        let allowStartInteraction: Bool
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case allowFixtureCommit = "allow_fixture_commit"
            case allowFixtureInteraction = "allow_fixture_interaction"
            case allowStartInteraction = "allow_start_interaction"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)),
                  !container.allKeys.isEmpty else {
                throw AgentEvalWireError.invalidRequest
            }
            allowFixtureCommit = try container.decodeIfPresent(Bool.self, forKey: .allowFixtureCommit) ?? false
            allowFixtureInteraction = try container.decodeIfPresent(Bool.self, forKey: .allowFixtureInteraction) ?? false
            allowStartInteraction = try container.decodeIfPresent(Bool.self, forKey: .allowStartInteraction) ?? false
        }
    }

    let taskID: String
    let prompt: String
    let start: Start
    let maxSteps: Int
    let policy: String
    let approvalPolicy: ApprovalPolicy?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case taskID = "task_id"
        case prompt, start
        case maxSteps = "max_steps"
        case policy
        case approvalPolicy = "approval_policy"
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["task_id", "prompt", "start", "max_steps", "policy", "approval_policy"]),
              ["task_id", "prompt", "start", "max_steps", "policy"].allSatisfy({ root[$0] != nil }),
              let start = root["start"] as? [String: Any],
              (Set(start.keys) == ["url"] || Set(start.keys) == ["app"]) else {
            throw AgentEvalWireError.invalidRequest
        }
        if let approval = root["approval_policy"] as? [String: Any],
           !Set(approval.keys).isSubset(of: ["allow_fixture_commit", "allow_fixture_interaction", "allow_start_interaction"]) {
            throw AgentEvalWireError.invalidRequest
        }
        if root["approval_policy"] != nil, !(root["approval_policy"] is [String: Any]) {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.validate()
        return request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed = Set(CodingKeys.allCases)
        let required: Set<CodingKeys> = [.taskID, .prompt, .start, .maxSteps, .policy]
        let actual = Set(container.allKeys)
        guard required.isSubset(of: actual), actual.isSubset(of: allowed) else {
            throw AgentEvalWireError.invalidRequest
        }
        taskID = try container.decode(String.self, forKey: .taskID)
        prompt = try container.decode(String.self, forKey: .prompt)
        start = try container.decode(Start.self, forKey: .start)
        maxSteps = try container.decode(Int.self, forKey: .maxSteps)
        policy = try container.decode(String.self, forKey: .policy)
        approvalPolicy = try container.decodeIfPresent(ApprovalPolicy.self, forKey: .approvalPolicy)
        try validate()
    }

    func validate() throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 128,
              taskID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 95
              }),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= ComputerUsePromptRequest.maximumPromptLength,
              (1...40).contains(maxSteps), Self.supportedPolicies.contains(policy) else {
            throw AgentEvalWireError.invalidRequest
        }
        if let url = start.url { try Self.validateStartURL(url) }
        if let app = start.app {
            guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  app.utf8.count <= 256 else { throw AgentEvalWireError.invalidRequest }
        }
    }

    func hostConfiguration(storageDirectory: URL) -> AgentHostFactory.Configuration {
        let surface: AgentHostFactory.InitialSurface?
        if let url = start.url { surface = .web(url) }
        else if let app = start.app { surface = .app(app) }
        else { surface = nil }
        return .init(maxSteps: maxSteps, initialSurface: surface,
            fileRoots: Self.syntheticFileRoots, storageDirectory: storageDirectory,
            policy: AgentPolicyModel(rawValue: policy) ?? .fara15_4b)
    }

    var allowsFixtureCommit: Bool { approvalPolicy?.allowFixtureCommit == true }
    var allowsFixtureInteraction: Bool { approvalPolicy?.allowFixtureInteraction == true }
    var allowsStartInteraction: Bool { approvalPolicy?.allowStartInteraction == true }
    var hasSyntheticFileRoot: Bool { !Self.syntheticFileRoots.isEmpty }

    private static func validateStartURL(_ value: String) throws {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              (scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(host)),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              URL(string: value, encodingInvalidCharacters: false)?.absoluteString == value else {
            throw AgentEvalWireError.invalidStartSurface
        }
    }

    private static var syntheticFileRoots: [URL] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        let root = resources.appendingPathComponent("files", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.path) ? [root] : []
    }

    private static let supportedPolicies = ["fara15-4b", "ui-tars15-7b"]
}

struct AgentEvalResponse: Encodable {
    let taskID: String
    let outcome: String
    let answer: String
    let episodePath: String
    let wallSeconds: Double
    let environment = "pixel"
    let policy: String
    let cropMode: String
    let requestedCropMode: String
    let realHostApp = true

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id", outcome, answer
        case episodePath = "episode_path"
        case wallSeconds = "wall_seconds"
        case environment, policy
        case cropMode = "crop_mode"
        case requestedCropMode = "requested_crop_mode"
        case realHostApp = "real_host_app"
    }
}

enum AgentEvalPixelMetadata {
    private static let cropModes: Set<String> = ["frontmost-window", "full-display"]

    static func actualCropMode(from data: Data?) -> String {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data),
              let values = root as? [String: Any],
              Set(values.keys) == Set(["active_backend", "crop_mode"]),
              let backend = values["active_backend"] as? String, backend == "pixel",
              let cropMode = values["crop_mode"] as? String,
              cropModes.contains(cropMode) else { return "unknown" }
        return cropMode
    }
}

enum AgentEvalWireError: Error {
    case invalidRequest
    case invalidStartSurface
    case bootstrapFailure
    case modelUnavailable
    case timedOut
}

extension AgentEvalRequest.Start: Equatable {}

#endif

#if DEBUG
import AppKit
import Darwin
import Foundation

private extension CodingUserInfoKey {
    static let agentEvalHomeDirectory = CodingUserInfoKey(rawValue: "agentEvalHomeDirectory")!
}

struct AgentEvalFirstObservation: Encodable {
    let frontmost_bundle_id: String
    let frontmost_app_name: String
    let frontmost_process_id: Int32
    let expected_start_bundle_id: String
    let expected_start_url: String
    let observed_start_url: String
    let start_surface_matches: Bool
    let visible_window_count: Int
    let selected_window_title: String
    let selected_window_number: UInt32?
    let selected_window_owner_process_id: Int32?
    let selected_window_bounds: [Double]?
    let valid: Bool

    static func requiresStartValidation(configured: Bool, isInitialObservation: Bool) -> Bool {
        configured && isInitialObservation
    }

    @MainActor
    static func expectedBundleID(startApp: String?, startURL: String?, registry: AgentAppRegistry) -> String? {
        let browserID = startURL.flatMap { value -> String? in
            guard let url = URL(string: value),
                  let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
            return Bundle(url: applicationURL)?.bundleIdentifier
        }
        return startApp.flatMap { try? registry.resolve($0).bundleID } ?? browserID
    }

    static func isInvalidStart(validating: Bool, receipt: AgentEvalFirstObservation?) -> Bool {
        validating && receipt?.valid != true
    }

    static func startURLCandidate(axURL: CFTypeRef?, documentURL: CFTypeRef?, sanitizedURL: String?) -> String? {
        rawURL(axURL) ?? rawURL(documentURL) ?? sanitizedURL
    }

    @MainActor
    static func observedStartURL(snapshot: PixelEnvironment.Snapshot) -> String? {
        guard let element = snapshot.window?.element else { return snapshot.url }
        let deadline = ContinuousClock.now + .milliseconds(300)
        var stack = [element]
        var visited = 0
        while !stack.isEmpty && visited < 160 && ContinuousClock.now < deadline {
            let current = stack.removeLast()
            visited += 1
            let role = ElementMarks.read(current, kAXRoleAttribute, deadline: deadline) as? String
            if CFEqual(current, element) || role == "AXWebArea" {
                if let value = startURLCandidate(axURL: ElementMarks.read(current, "AXURL", deadline: deadline),
                    documentURL: ElementMarks.read(current, kAXDocumentAttribute, deadline: deadline), sanitizedURL: nil) {
                    return value
                }
            }
            stack.append(contentsOf: ElementMarks.children(ElementMarks.read(current, kAXChildrenAttribute, deadline: deadline)))
        }
        return snapshot.url
    }

    static func rawURL(_ value: CFTypeRef?) -> String? {
        if let string = value as? String { return string }
        guard let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
    }

    @MainActor
    static func capture(snapshot: PixelEnvironment.Snapshot, expectedBundleID: String?,
                        expectedURL: String?) -> AgentEvalFirstObservation {
        let observedURL = observedStartURL(snapshot: snapshot)
        return capture(snapshotBundleID: snapshot.bundleID, appName: snapshot.appName,
            processID: snapshot.application?.processIdentifier ?? 0,
            expectedBundleID: expectedBundleID, expectedURL: expectedURL,
            observedURL: observedURL,
            startSurfaceMatches: matchesStart(expectedBundleID: expectedBundleID,
                observedBundleID: snapshot.bundleID, expectedURL: expectedURL, observedURL: observedURL),
            visibleWindowCount: snapshot.visibleWindowCount, windowTitle: snapshot.title,
            windowNumber: snapshot.activeWindowNumber, windowOwnerProcessID: snapshot.activeWindowOwnerProcessID,
            windowBounds: snapshot.activeWindowBounds)
    }

    static func capture(snapshotBundleID: String, appName: String, processID: Int32,
                        expectedBundleID: String?, expectedURL: String?, observedURL: String?,
                        startSurfaceMatches: Bool, visibleWindowCount: Int, windowTitle: String,
                        windowNumber: UInt32?, windowOwnerProcessID: Int32?, windowBounds: CGRect?) -> Self {
        let expectedURL = expectedURL.flatMap(normalizedURL) ?? ""
        let observedURL = observedURL.flatMap(normalizedURL) ?? ""
        let bounds = windowBounds.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        return .init(frontmost_bundle_id: snapshotBundleID, frontmost_app_name: appName,
            frontmost_process_id: processID, expected_start_bundle_id: expectedBundleID ?? "",
            expected_start_url: expectedURL, observed_start_url: observedURL,
            start_surface_matches: startSurfaceMatches, visible_window_count: visibleWindowCount,
            selected_window_title: windowTitle, selected_window_number: windowNumber,
            selected_window_owner_process_id: windowOwnerProcessID, selected_window_bounds: bounds,
            valid: visibleWindowCount == 1 && windowBounds != nil && snapshotBundleID != "unknown"
                && processID > 0 && processID == windowOwnerProcessID && startSurfaceMatches)
    }

    static func matchesStart(expectedBundleID: String?, observedBundleID: String,
                             expectedURL: String?, observedURL: String?) -> Bool {
        guard let expectedBundleID, expectedBundleID == observedBundleID else { return false }
        guard let expectedURL else { return true }
        return observedURL.flatMap(normalizedURL) == normalizedURL(expectedURL)
    }

    static func normalizedURL(_ value: String) -> String? {
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased() else { return nil }
        parts.scheme = scheme; parts.host = host; parts.fragment = nil
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string
    }
}

@MainActor
extension PixelEnvironment {
    func captureEvaluationStart() async throws -> Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var last: Snapshot?
        repeat {
            try checkActive()
            let snapshot = try await captureSnapshotForObservation()
            last = snapshot
            let observedURL = AgentEvalFirstObservation.observedStartURL(snapshot: snapshot)
            if snapshot.visibleWindowCount == 1,
               snapshot.activeWindowBounds != nil,
               snapshot.application?.processIdentifier == snapshot.activeWindowOwnerProcessID,
               AgentEvalFirstObservation.matchesStart(expectedBundleID: expectedStartBundleID,
                   observedBundleID: snapshot.bundleID, expectedURL: startURL, observedURL: observedURL) {
                return snapshot
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        guard let last else { throw AgentEnvironmentError.unavailable("Evaluation did not produce an initial window.") }
        return last
    }
}

struct AgentEvalPixelMetadataRecord: Encodable {
    let active_backend = "pixel"
    let crop_mode: String
    let first_observation: AgentEvalFirstObservation?
    let voice_overlay_escape_count: Int
    let voice_overlay_detected_during_capture: Bool

    static func write(to url: URL, cropMode: String, firstObservation: AgentEvalFirstObservation?,
                      escapeCount: Int, detectedDuringCapture: Bool) throws {
        let record = Self(crop_mode: cropMode, first_observation: firstObservation,
            voice_overlay_escape_count: escapeCount, voice_overlay_detected_during_capture: detectedDuringCapture)
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

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
    let setupDocument: URL?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case taskID = "task_id"
        case prompt, start
        case maxSteps = "max_steps"
        case policy
        case approvalPolicy = "approval_policy"
        case setupDocument = "setup_document"
    }

    static func decodeStrict(_ data: Data,
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["task_id", "prompt", "start", "max_steps", "policy", "approval_policy", "setup_document"]),
              !root.keys.contains("setup_document") || root["setup_document"] is String,
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
        let decoder = JSONDecoder()
        decoder.userInfo[.agentEvalHomeDirectory] = homeDirectory
        let request = try decoder.decode(Self.self, from: data)
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
        if let path = try container.decodeIfPresent(String.self, forKey: .setupDocument) {
            guard start.app != nil, approvalPolicy?.allowStartInteraction == true,
                  let task = ProcessInfo.processInfo.environment["EVAL_TASK_ID"],
                  let token = ProcessInfo.processInfo.environment["EVAL_RUN_TOKEN"],
                  let document = AgentEvalSetupDocument.authorized(path: path, taskID: task, token: token,
                    homeDirectory: decoder.userInfo[.agentEvalHomeDirectory] as? URL ?? FileManager.default.homeDirectoryForCurrentUser) else {
                throw AgentEvalWireError.invalidRequest
            }
            setupDocument = document
        } else {
            setupDocument = nil
        }
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
            fileRoots: Self.syntheticFileRoots, storageDirectory: storageDirectory, requireCleanStart: true,
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

    private static let supportedPolicies = ["fara15-4b", "ui-tars15-7b", "gui-owl15-4b"]
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
              let keys = Set(values.keys),
              keys == Set(["active_backend", "crop_mode"])
                || keys == Set(["active_backend", "crop_mode", "first_observation"])
                || keys == Set(["active_backend", "crop_mode", "voice_overlay_escape_count", "voice_overlay_detected_during_capture"])
                || keys == Set(["active_backend", "crop_mode", "first_observation", "voice_overlay_escape_count", "voice_overlay_detected_during_capture"]),
              let backend = values["active_backend"] as? String, backend == "pixel",
              let cropMode = values["crop_mode"] as? String,
              cropModes.contains(cropMode) else { return "unknown" }
        if keys.contains("voice_overlay_escape_count") {
            guard let escapeCount = values["voice_overlay_escape_count"] as? Int, escapeCount >= 0,
                  values["voice_overlay_detected_during_capture"] is Bool else { return "unknown" }
        }
        return cropMode
    }

    static func hasValidFirstObservation(from data: Data?) -> Bool {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data),
              let values = root as? [String: Any],
              let state = values["first_observation"] as? [String: Any],
              Set(state.keys) == Set(["frontmost_bundle_id", "frontmost_app_name", "frontmost_process_id",
                  "expected_start_bundle_id", "expected_start_url", "observed_start_url", "start_surface_matches",
                  "visible_window_count", "selected_window_title", "selected_window_number",
                  "selected_window_owner_process_id", "selected_window_bounds", "valid"]),
              let bundleID = state["frontmost_bundle_id"] as? String, !bundleID.isEmpty,
              let appName = state["frontmost_app_name"] as? String, !appName.isEmpty,
              let frontmostPID = state["frontmost_process_id"] as? Int, frontmostPID > 0,
              let expectedBundleID = state["expected_start_bundle_id"] as? String,
              !expectedBundleID.isEmpty,
              expectedBundleID == bundleID,
              let expectedURL = state["expected_start_url"] as? String,
              let observedURL = state["observed_start_url"] as? String,
              let startMatches = state["start_surface_matches"] as? Bool, startMatches,
              state["selected_window_title"] is String,
              let count = state["visible_window_count"] as? Int, count == 1,
              let valid = state["valid"] as? Bool, valid,
              let number = state["selected_window_number"] as? NSNumber, number.uint32Value > 0,
              let ownerPID = state["selected_window_owner_process_id"] as? Int, ownerPID == frontmostPID,
              let bounds = state["selected_window_bounds"] as? [NSNumber], bounds.count == 4,
              bounds.allSatisfy({ $0.doubleValue.isFinite }), bounds[2].doubleValue > 0, bounds[3].doubleValue > 0 else {
            return false
        }
        guard expectedURL.isEmpty || observedURL == expectedURL else { return false }
        return true
    }
}

enum AgentEvalWireError: Error {
    case invalidRequest
    case invalidStartSurface
    case bootstrapFailure
    case modelUnavailable
    case timedOut
}

enum AgentEvalSetupDocument {
    static func authorized(path: String, taskID: String, token: String,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard !taskID.isEmpty, taskID.utf8.count <= 128,
              taskID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              token.utf8.count == 32,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let home = homeDirectory.standardizedFileURL
        let root = home.appendingPathComponent("AgentEval", isDirectory: true)
        let run = root.appendingPathComponent("\(taskID)-\(token)", isDirectory: true)
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.isFileURL, file.path == path, file.deletingLastPathComponent() == run,
              !file.lastPathComponent.isEmpty, file.lastPathComponent != ".", file.lastPathComponent != "..",
              root.resolvingSymlinksInPath() == root,
              run.resolvingSymlinksInPath() == run,
              file.resolvingSymlinksInPath() == file,
              let rootAttributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              (rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              let runAttributes = try? FileManager.default.attributesOfItem(atPath: run.path),
              runAttributes[.type] as? FileAttributeType == .typeDirectory,
              (runAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (runAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              let fileAttributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              fileAttributes[.type] as? FileAttributeType == .typeRegular,
              (fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (((fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077) == 0,
              (fileAttributes[.size] as? NSNumber)?.intValue == 0 else { return nil }
        return file
    }
}

extension AgentEvalRequest.Start: Equatable {}

#endif

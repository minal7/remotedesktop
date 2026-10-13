#if DEBUG
import ApplicationServices
import CoreGraphics
import Foundation
import Security

struct AgentEvalPreflightRequest: Decodable {
    let operation: String
    let probeURL: String
    let policy: String
    let trustSeeds: [AgentEvalTrustSeed]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation
        case probeURL = "probe_url"
        case policy
        case trustSeeds = "trust_seeds"
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["operation", "probe_url", "policy", "trust_seeds"]),
              ["operation", "probe_url", "trust_seeds"].allSatisfy({ object[$0] != nil }),
              object["operation"] as? String == "preflight",
              let url = object["probe_url"] as? String,
              let seeds = object["trust_seeds"] as? [[String: Any]],
              seeds.allSatisfy({ Set($0.keys) == ["kind", "identity"] }) else {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.operation == "preflight", AgentPolicyModel(rawValue: request.policy) != nil else {
            throw AgentEvalWireError.invalidRequest
        }
        try Self.validateProbeURL(url)
        try Self.validateTrustSeeds(request.trustSeeds, probeURL: url)
        return request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)),
              container.contains(.operation), container.contains(.probeURL), container.contains(.trustSeeds) else {
            throw AgentEvalWireError.invalidRequest
        }
        operation = try container.decode(String.self, forKey: .operation)
        probeURL = try container.decode(String.self, forKey: .probeURL)
        policy = try container.decodeIfPresent(String.self, forKey: .policy) ?? "fara15-4b"
        trustSeeds = try container.decode([AgentEvalTrustSeed].self, forKey: .trustSeeds)
    }

    private static func validateProbeURL(_ value: String) throws {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(), host == "127.0.0.1", parts.port == 8765,
              parts.user == nil, parts.password == nil,
              URL(string: value, encodingInvalidCharacters: false)?.absoluteString == value else {
            throw AgentEvalWireError.invalidStartSurface
        }
    }

    private static func validateTrustSeeds(_ seeds: [AgentEvalTrustSeed], probeURL: String) throws {
        let apps: Set<String> = ["Safari", "TextEdit", "Finder", "Notes"]
        guard (1...5).contains(seeds.count), Set(seeds).count == seeds.count else { throw AgentEvalWireError.invalidRequest }
        for seed in seeds {
            if seed.kind == "app" {
                guard apps.contains(seed.identity) else { throw AgentEvalWireError.invalidRequest }
            } else if seed.kind == "web" {
                guard seed.identity == "http://127.0.0.1:8765",
                      let parts = URLComponents(string: seed.identity), parts.scheme == "http",
                      parts.host == "127.0.0.1", parts.port == 8765, parts.user == nil, parts.password == nil,
                      parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
                      let probe = URLComponents(string: probeURL), probe.host == parts.host, probe.port == parts.port else {
                    throw AgentEvalWireError.invalidRequest
                }
            } else { throw AgentEvalWireError.invalidRequest }
        }
        guard Set(seeds.filter { $0.kind == "app" }.map(\.identity)).isSubset(of: apps),
              seeds.filter({ $0.kind == "web" }).count <= 1 else { throw AgentEvalWireError.invalidRequest }
    }
}

struct AgentEvalTrustSeed: Decodable, Encodable, Equatable, Hashable { let kind: String; let identity: String }

struct AgentEvalPreflightCheck: Encodable, Equatable {
    let name: String
    let status: String
    let detail: String
}

struct AgentEvalTrustReceipt: Encodable, Equatable { let kind: String; let identity: String }
struct AgentEvalTrustSeedResult { let trustedSurfaces: [AgentEvalTrustReceipt]; let storePath: String }

struct AgentEvalPreflightResponse: Encodable, Equatable {
    let operation = "preflight"
    let realHostApp = true
    let outcome: String
    let checks: [AgentEvalPreflightCheck]
    let blockedReason: String?
    let ownerAction: String?
    let activeEnvironment = "pixel"
    let policy: String
    let modelStatus: String?
    let trustedSurfaces: [AgentEvalTrustReceipt]
    let trustStorePath: String

    private enum CodingKeys: String, CodingKey {
        case operation, outcome, checks, policy
        case realHostApp = "real_host_app"
        case blockedReason = "blocked_reason"
        case ownerAction = "owner_action"
        case activeEnvironment = "active_environment"
        case modelStatus = "model_status"
        case trustedSurfaces = "trusted_surfaces"
        case trustStorePath = "trust_store_path"
    }

    static func invalidRequest() -> Self {
        .init(outcome: "infra_blocked", checks: [
            .init(name: "request", status: "blocked", detail: "The preflight request was invalid."),
        ], blockedReason: "The preflight request did not match the required protocol.",
           ownerAction: "Update the evaluation runner to send a loopback fixture probe_url, supported policy, and explicit trust seeds.",
           policy: "none", modelStatus: nil, trustedSurfaces: [], trustStorePath: "not-written")
    }
}

struct AgentEvalPreflightDependencies {
    let signedHostCheck: @MainActor () -> Bool
    let accessibilityCheck: @MainActor () -> Bool
    let screenRecordingCheck: @MainActor () -> Bool
    let pixelReadinessCheck: @MainActor () async -> PixelEnvironmentReadiness
    let modelCheck: @MainActor (AgentPolicyModel) async -> String?
    let trustSeeder: @MainActor ([AgentEvalTrustSeed]) throws -> AgentEvalTrustSeedResult
}

enum AgentEvalPreflight {
    @MainActor
    static func run(_ request: AgentEvalPreflightRequest) async -> AgentEvalPreflightResponse {
        await run(request, dependencies: liveDependencies())
    }

    @MainActor
    static func run(_ request: AgentEvalPreflightRequest,
                    dependencies: AgentEvalPreflightDependencies) async -> AgentEvalPreflightResponse {
        var checks: [AgentEvalPreflightCheck] = []
        guard dependencies.signedHostCheck() else {
            return blocked("host_process", "The running host app signature could not be verified.",
                "Launch the signed Remote Desktop Host app build, then rerun preflight.", checks: checks, policy: request.policy)
        }
        checks.append(.init(name: "host_process", status: "passed",
            detail: "PID \(ProcessInfo.processInfo.processIdentifier) is running as the signed Remote Desktop Host app."))

        guard dependencies.accessibilityCheck() else {
            return blocked("accessibility", "Accessibility permission is unavailable.",
                "Grant Accessibility to Remote Desktop Host in System Settings > Privacy & Security, then rerun preflight.",
                checks: checks, policy: request.policy)
        }
        checks.append(.init(name: "accessibility", status: "passed", detail: "Accessibility is available."))

        guard dependencies.screenRecordingCheck() else {
            return blocked("screen_recording", "Screen Recording permission is unavailable.",
                "Grant Screen Recording to Remote Desktop Host in System Settings > Privacy & Security, then rerun preflight.",
                checks: checks, policy: request.policy)
        }
        checks.append(.init(name: "screen_recording", status: "passed", detail: "Screen Recording is available."))

        let pixel = await dependencies.pixelReadinessCheck()
        guard pixel.ready, pixel.activeBackend == "pixel" else {
            return blocked("pixel_environment", pixel.detail,
                "Make Pixel screenshot capture and Accessibility available, then rerun preflight.",
                checks: checks, policy: request.policy)
        }
        checks.append(.init(name: "pixel_environment", status: "passed", detail: pixel.detail))

        guard let model = AgentPolicyModel(rawValue: request.policy) else {
            return blocked("model", "The requested local model policy is unsupported.",
                "Select fara15-4b or ui-tars15-7b, then rerun preflight.", checks: checks, policy: request.policy)
        }
        if let modelFailure = await dependencies.modelCheck(model) {
            return blocked("model", "The local \(model.rawValue) runtime did not become ready: \(modelFailure)",
                "Complete setup for the selected local model in the signed host app, then rerun preflight.",
                checks: checks, policy: request.policy, modelStatus: "failed")
        }
        checks.append(.init(name: "model", status: "passed", detail: "Selected local model loaded and passed its runtime health check."))
        let seedResult: AgentEvalTrustSeedResult
        do { seedResult = try dependencies.trustSeeder(request.trustSeeds) }
        catch {
            return blocked("trust", "Suite trust could not be recorded: \(error.localizedDescription)",
                "Resolve the installed app or persistent trust-store issue, then rerun preflight.",
                checks: checks, policy: model.rawValue, modelStatus: "loaded")
        }
        guard seedResult.trustedSurfaces.count == request.trustSeeds.count else {
            return blocked("trust", "The host did not verify every requested suite trust identity.",
                "Use the current signed host app evaluation driver, then rerun preflight.",
                checks: checks, policy: model.rawValue, modelStatus: "loaded")
        }
        checks.append(.init(name: "trust", status: "passed", detail: "Verified \(seedResult.trustedSurfaces.count) suite app/origin identities in the persistent host trust store."))
        return .init(outcome: "ready", checks: checks, blockedReason: nil, ownerAction: nil,
            policy: model.rawValue, modelStatus: "loaded", trustedSurfaces: seedResult.trustedSurfaces,
            trustStorePath: seedResult.storePath)
    }

    @MainActor
    private static func liveDependencies() -> AgentEvalPreflightDependencies {
        let permissions = SystemPermissionsProvider()
        return AgentEvalPreflightDependencies(
            signedHostCheck: isSignedHost,
            accessibilityCheck: { permissions.accessibilityGranted() },
            screenRecordingCheck: { permissions.screenRecordingGranted() },
            pixelReadinessCheck: { await PixelEnvironment.readiness() },
            modelCheck: ensureModelReady,
            trustSeeder: seedTrust)
    }

    private static func isSignedHost() -> Bool {
        guard Bundle.main.bundleIdentifier?.isEmpty == false,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    @MainActor
    private static func ensureModelReady(_ model: AgentPolicyModel) async -> String? {
        do {
            let inputs = try await resolveRuntimeInputs(model: model)
            return await OSAtlasLlamaRuntime.shared.ensureAgentVisionReady(inputs)
        } catch {
            await OSAtlasLlamaRuntime.shared.shutdown()
            return error.localizedDescription
        }
    }

    @MainActor
    static func resolveRuntimeInputs(model: AgentPolicyModel) async throws -> AgentVisionRuntimeInputs {
        let installer = ComputerUseInstaller()
        let receipt = model == .fara15_4b ? await installer.currentInstallation() : nil
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        return try AgentVisionRuntimeInputs.resolve(model: model,
            faraInputs: try faraInputs(receipt, model: model, runtimeDirectory: runtimeDirectory),
            modelRootURL: HostComputerUseManager.modelDirectoryURL.appendingPathComponent("Models", isDirectory: true),
            runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
    }

    private static func faraInputs(_ receipt: ComputerUseInstallationReceipt?, model: AgentPolicyModel,
                                   runtimeDirectory: URL) throws -> ComputerUseFaraRuntimeInputs? {
        guard model == .fara15_4b else { return nil }
        guard let receipt,
              case let .fara(inputs) = try OSAtlasRuntimeInputResolver().resolveAvailablePackage(
                receipt: receipt, runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL) else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        return inputs
    }

    @MainActor
    private static func seedTrust(_ seeds: [AgentEvalTrustSeed]) throws -> AgentEvalTrustSeedResult {
        let approvedBundles = ["Safari": "com.apple.Safari", "TextEdit": "com.apple.TextEdit",
                               "Finder": "com.apple.finder", "Notes": "com.apple.Notes"]
        let store = try AgentHostFactory.persistentTrustStore()
        let receipts = try seeds.map { seed -> AgentEvalTrustReceipt in
            if seed.kind == "app" {
                guard let bundleID = approvedBundles[seed.identity] else { throw AgentEvalWireError.invalidRequest }
                return .init(kind: "app", identity: bundleID)
            }
            return .init(kind: "web", identity: seed.identity)
        }
        for item in receipts {
            guard let kind = AgentScope.Kind(rawValue: item.kind) else { throw AgentEvalWireError.invalidRequest }
            try store.markTrusted(kind: kind, identity: item.identity)
            guard try store.isTrusted(kind: kind, identity: item.identity) else { throw AgentEvalWireError.bootstrapFailure }
        }
        return .init(trustedSurfaces: receipts, storePath: AgentHostFactory.persistentTrustDirectory().path)
    }

    @MainActor
    private static func blocked(_ name: String, _ reason: String, _ action: String,
                                checks: [AgentEvalPreflightCheck], policy: String,
                                modelStatus: String? = nil) -> AgentEvalPreflightResponse {
        .init(outcome: "infra_blocked", checks: checks + [
            .init(name: name, status: "blocked", detail: reason),
        ], blockedReason: reason, ownerAction: action, policy: policy, modelStatus: modelStatus,
            trustedSurfaces: [], trustStorePath: AgentHostFactory.persistentTrustDirectory().path)
    }
}
#endif

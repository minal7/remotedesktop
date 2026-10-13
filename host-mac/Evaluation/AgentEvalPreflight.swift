#if DEBUG
import ApplicationServices
import CoreGraphics
import Foundation
import Security

struct AgentEvalPreflightRequest: Decodable {
    let operation: String
    let probeURL: String
    let policy: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation
        case probeURL = "probe_url"
        case policy
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["operation", "probe_url", "policy"]),
              ["operation", "probe_url"].allSatisfy({ object[$0] != nil }),
              object["operation"] as? String == "preflight",
              let url = object["probe_url"] as? String else {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.operation == "preflight", AgentPolicyModel(rawValue: request.policy) != nil else {
            throw AgentEvalWireError.invalidRequest
        }
        try Self.validateProbeURL(url)
        return request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)),
              container.contains(.operation), container.contains(.probeURL) else {
            throw AgentEvalWireError.invalidRequest
        }
        operation = try container.decode(String.self, forKey: .operation)
        probeURL = try container.decode(String.self, forKey: .probeURL)
        policy = try container.decodeIfPresent(String.self, forKey: .policy) ?? "fara15-4b"
    }

    private static func validateProbeURL(_ value: String) throws {
        guard let parts = URLComponents(string: value), parts.scheme == "http",
              let host = parts.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              parts.user == nil, parts.password == nil,
              URL(string: value, encodingInvalidCharacters: false)?.absoluteString == value else {
            throw AgentEvalWireError.invalidStartSurface
        }
    }
}

struct AgentEvalPreflightCheck: Encodable, Equatable {
    let name: String
    let status: String
    let detail: String
}

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

    private enum CodingKeys: String, CodingKey {
        case operation, outcome, checks, policy
        case realHostApp = "real_host_app"
        case blockedReason = "blocked_reason"
        case ownerAction = "owner_action"
        case activeEnvironment = "active_environment"
        case modelStatus = "model_status"
    }

    static func invalidRequest() -> Self {
        .init(outcome: "infra_blocked", checks: [
            .init(name: "request", status: "blocked", detail: "The preflight request was invalid."),
        ], blockedReason: "The preflight request did not match the required protocol.",
           ownerAction: "Update the evaluation runner to send a loopback fixture probe_url and supported policy.",
           policy: "none", modelStatus: nil)
    }
}

struct AgentEvalPreflightDependencies {
    let signedHostCheck: @MainActor () -> Bool
    let accessibilityCheck: @MainActor () -> Bool
    let screenRecordingCheck: @MainActor () -> Bool
    let pixelReadinessCheck: @MainActor () async -> PixelEnvironmentReadiness
    let modelCheck: @MainActor (AgentPolicyModel) async -> String?
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
        return .init(outcome: "ready", checks: checks, blockedReason: nil, ownerAction: nil,
            policy: model.rawValue, modelStatus: "loaded")
    }

    @MainActor
    private static func liveDependencies() -> AgentEvalPreflightDependencies {
        let permissions = SystemPermissionsProvider()
        return AgentEvalPreflightDependencies(
            signedHostCheck: isSignedHost,
            accessibilityCheck: { permissions.accessibilityGranted() },
            screenRecordingCheck: { permissions.screenRecordingGranted() },
            pixelReadinessCheck: { await PixelEnvironment.readiness() },
            modelCheck: ensureModelReady)
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
            let installer = ComputerUseInstaller()
            let receipt = model == .fara15_4b ? await installer.currentInstallation() : nil
            let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
            let inputs = try AgentVisionRuntimeInputs.resolve(model: model, faraInputs: try faraInputs(receipt, model: model,
                runtimeDirectory: runtimeDirectory),
                modelRootURL: HostComputerUseManager.modelDirectoryURL.appendingPathComponent("Models", isDirectory: true),
                runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
            return await OSAtlasLlamaRuntime.shared.ensureAgentVisionReady(inputs)
        } catch {
            await OSAtlasLlamaRuntime.shared.shutdown()
            return error.localizedDescription
        }
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

    private static func blocked(_ name: String, _ reason: String, _ action: String,
                                checks: [AgentEvalPreflightCheck], policy: String,
                                modelStatus: String? = nil) -> AgentEvalPreflightResponse {
        .init(outcome: "infra_blocked", checks: checks + [
            .init(name: name, status: "blocked", detail: reason),
        ], blockedReason: reason, ownerAction: action, policy: policy, modelStatus: modelStatus)
    }
}
#endif

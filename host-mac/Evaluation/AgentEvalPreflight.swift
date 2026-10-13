#if DEBUG
import ApplicationServices
import CoreGraphics
import Foundation
import Security

struct AgentEvalPreflightRequest: Decodable {
    let operation: String
    let probeURL: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation
        case probeURL = "probe_url"
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "probe_url"],
              object["operation"] as? String == "preflight",
              let url = object["probe_url"] as? String else {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.operation == "preflight" else { throw AgentEvalWireError.invalidRequest }
        try Self.validateProbeURL(url)
        return request
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
    let safariExtensionStatus: String?
    let safariPingCount: Int?
    let safariPingP95Milliseconds: Double?
    let modelStatus: String?

    private enum CodingKeys: String, CodingKey {
        case operation, outcome, checks
        case realHostApp = "real_host_app"
        case blockedReason = "blocked_reason"
        case ownerAction = "owner_action"
        case safariExtensionStatus = "safari_extension_status"
        case safariPingCount = "safari_ping_count"
        case safariPingP95Milliseconds = "safari_ping_p95_ms"
        case modelStatus = "model_status"
    }

    static func invalidRequest() -> Self {
        .init(outcome: "infra_blocked", checks: [
            .init(name: "request", status: "blocked", detail: "The preflight request was invalid."),
        ], blockedReason: "The preflight request did not match the required protocol.",
           ownerAction: "Update the evaluation runner to send operation=preflight and a loopback fixture probe_url.",
           safariExtensionStatus: nil, safariPingCount: nil,
           safariPingP95Milliseconds: nil, modelStatus: nil)
    }
}

struct AgentEvalSafariProbeResult: Equatable {
    let extensionStatus: String
    let sampleCount: Int
    let p95Milliseconds: Double
}

struct AgentEvalPreflightDependencies {
    let signedHostCheck: @MainActor () -> Bool
    let accessibilityCheck: @MainActor () -> Bool
    let screenRecordingCheck: @MainActor () -> Bool
    let helperCheck: @MainActor () throws -> String
    let safariProbe: @MainActor (String) async throws -> AgentEvalSafariProbeResult
    let modelCheck: @MainActor () async -> String?
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
                "Launch the signed Remote Desktop Host app build, then rerun preflight.", checks: checks)
        }
        checks.append(.init(name: "host_process", status: "passed",
            detail: "PID \(ProcessInfo.processInfo.processIdentifier) is running as the signed Remote Desktop Host app."))

        guard dependencies.accessibilityCheck() else {
            return blocked("accessibility", "Accessibility or input control permission is unavailable.",
                "Grant Accessibility to Remote Desktop Host in System Settings > Privacy & Security, then rerun preflight.", checks: checks)
        }
        checks.append(.init(name: "accessibility", status: "passed", detail: "Accessibility and input control are available."))

        guard dependencies.screenRecordingCheck() else {
            return blocked("screen_recording", "Screen Recording permission is unavailable.",
                "Grant Screen Recording to Remote Desktop Host in System Settings > Privacy & Security, then rerun preflight.", checks: checks)
        }
        checks.append(.init(name: "screen_recording", status: "passed", detail: "Screen Recording is available."))

        do {
            let status = try dependencies.helperCheck()
            guard status == "enabled" else {
                return blocked("safari_helper", "Safari Bridge helper status is \(status).",
                    "Enable the Remote Desktop Host helper in System Settings > General > Login Items & Extensions, then rerun preflight.", checks: checks)
            }
            checks.append(.init(name: "safari_helper", status: "passed", detail: status))
        } catch let error as SafariBridgeHelperServiceError {
            let reason = "\(error.localizedDescription) (status: \(SafariBridgeHelperService.statusName))"
            return blocked("safari_helper", reason,
                helperOwnerAction(error), checks: checks)
        } catch {
            return blocked("safari_helper", "The bundled Safari Bridge helper is unavailable.",
                "Enable the Remote Desktop Host helper in System Settings > General > Login Items & Extensions, then rerun preflight.", checks: checks)
        }

        let probe: AgentEvalSafariProbeResult
        do {
            probe = try await dependencies.safariProbe(request.probeURL)
        } catch {
            return blocked("safari_extension", "Safari bound-tab health probe failed: \(error.localizedDescription)",
                "Enable the Remote Desktop Host extension in Safari > Settings > Extensions and allow it on the local fixture page, then rerun preflight.", checks: checks,
                extensionStatus: "unknown")
        }
        guard probe.extensionStatus == "enabled", probe.sampleCount == 100,
              probe.p95Milliseconds.isFinite, probe.p95Milliseconds >= 0 else {
            return blocked("safari_extension", "Safari extension state or ping results were incomplete.",
                "Enable the Remote Desktop Host extension in Safari > Settings > Extensions and allow it on the local fixture page, then rerun preflight.", checks: checks,
                extensionStatus: probe.extensionStatus, pingCount: probe.sampleCount,
                pingP95: probe.p95Milliseconds)
        }
        checks.append(.init(name: "safari_extension", status: "passed",
            detail: "Enabled; 100 bound-tab pings completed (p95 \(probe.p95Milliseconds) ms)."))

        if let modelFailure = await dependencies.modelCheck() {
            return blocked("model", "The local Fara model runtime did not become ready: \(modelFailure)",
                "Complete Fara model setup in the signed Remote Desktop Host app, then rerun preflight.", checks: checks,
                extensionStatus: probe.extensionStatus, pingCount: probe.sampleCount,
                pingP95: probe.p95Milliseconds, modelStatus: "failed")
        }
        checks.append(.init(name: "model", status: "passed", detail: "Local Fara model loaded and passed its runtime health check."))
        return .init(outcome: "ready", checks: checks, blockedReason: nil, ownerAction: nil,
            safariExtensionStatus: probe.extensionStatus, safariPingCount: probe.sampleCount,
            safariPingP95Milliseconds: probe.p95Milliseconds, modelStatus: "loaded")
    }

    @MainActor
    private static func liveDependencies() -> AgentEvalPreflightDependencies {
        let permissions = SystemPermissionsProvider()
        return AgentEvalPreflightDependencies(
            signedHostCheck: isSignedHost,
            accessibilityCheck: { permissions.accessibilityGranted() },
            screenRecordingCheck: { permissions.screenRecordingGranted() },
            helperCheck: { try SafariBridgeHelperService.ensureRegistered() },
            safariProbe: { url in
                let report = try await SafariBridgeHealthProbe.run(testURL: url, sampleCount: 100)
                return .init(extensionStatus: report.extensionStatus,
                    sampleCount: report.sampleCount, p95Milliseconds: report.p95Milliseconds)
            },
            modelCheck: startAndStopFaraRuntime)
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
    private static func startAndStopFaraRuntime() async -> String? {
        let installer = ComputerUseInstaller()
        guard let receipt = await installer.currentInstallation() else {
            return "No verified Fara installation receipt is available."
        }
        do {
            let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
            let package = try OSAtlasRuntimeInputResolver().resolveAvailablePackage(receipt: receipt,
                runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
            guard case .fara(let inputs) = package else { return "The installed runtime package is not Fara 1.5." }
            let runtime = OSAtlasLlamaRuntime.shared
            _ = try await runtime.activateFara(inputs)
            await runtime.shutdown()
            return nil
        } catch {
            await OSAtlasLlamaRuntime.shared.shutdown()
            return error.localizedDescription
        }
    }

    private static func helperOwnerAction(_ error: SafariBridgeHelperServiceError) -> String {
        switch error {
        case .helperRequiresApproval:
            "System Settings → General → Login Items & Extensions → allow Remote Desktop Host"
        case .helperMissingFromBundle:
            "Rebuild or reinstall the signed Remote Desktop Host app with its bundled Safari Bridge helper."
        case .registrationFailed:
            "Send the registration failure domain and code to the app developer for diagnosis, then reinstall the signed host app."
        case .helperNotRegistered, .statusUnavailable:
            "Enable or register the Remote Desktop Host helper in System Settings > General > Login Items & Extensions, then rerun preflight."
        }
    }

    private static func blocked(_ name: String, _ reason: String, _ action: String,
                                checks: [AgentEvalPreflightCheck], extensionStatus: String? = nil,
                                pingCount: Int? = nil, pingP95: Double? = nil,
                                modelStatus: String? = nil) -> AgentEvalPreflightResponse {
        let failed = AgentEvalPreflightCheck(name: name, status: "blocked", detail: reason)
        return .init(outcome: "infra_blocked", checks: checks + [failed], blockedReason: reason,
            ownerAction: action, safariExtensionStatus: extensionStatus,
            safariPingCount: pingCount, safariPingP95Milliseconds: pingP95, modelStatus: modelStatus)
    }
}
#endif

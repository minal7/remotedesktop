import Foundation
import SafariServices

struct SafariBridgeHealthReport: Equatable {
    let extensionStatus: String
    let sampleCount: Int
    let p95Milliseconds: Double
    let latenciesMilliseconds: [Double]
}

enum SafariBridgeHealthProbeError: LocalizedError, Equatable {
    case invalidTestURL
    case extensionStateUnavailable
    case extensionDisabled
    case invalidSampleCount
    case missingTabBinding

    var errorDescription: String? {
        switch self {
        case .invalidTestURL: "Health probe requires an HTTP loopback fixture URL."
        case .extensionStateUnavailable: "Safari extension state could not be read."
        case .extensionDisabled: "The Remote Desktop Host Safari extension is disabled."
        case .invalidSampleCount: "Health probe requires exactly 100 ping samples."
        case .missingTabBinding: "Safari did not return a tab and window binding for the probe task."
        }
    }
}

@MainActor
enum SafariBridgeHealthProbe {
    static func run(testURL: String, sampleCount: Int = 100) async throws -> SafariBridgeHealthReport {
        guard isLoopbackFixtureURL(testURL) else { throw SafariBridgeHealthProbeError.invalidTestURL }
        guard sampleCount == 100 else { throw SafariBridgeHealthProbeError.invalidSampleCount }
        let state = try await extensionState()
        guard state.isEnabled else { throw SafariBridgeHealthProbeError.extensionDisabled }

        let taskToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let transport = SafariBridgeTransport(timeout: 2)
        try await transport.startTask(taskToken: taskToken)
        do {
            let opened = try await transport.perform(.init(taskToken: taskToken, operation: .openTab, url: testURL))
            guard let tabID = opened.tabId, let windowID = opened.windowId else {
                throw SafariBridgeHealthProbeError.missingTabBinding
            }
            let latencies = try await pingSamples(transport: transport, taskToken: taskToken,
                tabID: tabID, windowID: windowID)
            await transport.endTask(taskToken: taskToken)
            let ordered = latencies.sorted()
            return SafariBridgeHealthReport(extensionStatus: "enabled", sampleCount: latencies.count,
                p95Milliseconds: ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1],
                latenciesMilliseconds: latencies)
        } catch {
            await transport.endTask(taskToken: taskToken)
            throw error
        }
    }

    private static func pingSamples(transport: SafariBridgeTransport, taskToken: String,
                                    tabID: Int, windowID: Int) async throws -> [Double] {
        var results: [Double] = []
        results.reserveCapacity(100)
        for _ in 0..<100 {
            let command = SafariBridgeCommand(taskToken: taskToken, operation: .ping,
                tabId: tabID, windowId: windowID, nonce: UUID().uuidString.lowercased())
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await transport.perform(command)
            results.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return results
    }

    private static func extensionState() async throws -> SFSafariExtensionState {
        try await withCheckedThrowingContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(
                withIdentifier: SafariBridgeXPCNames.safariExtensionIdentifier) { state, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let state { continuation.resume(returning: state) }
                    else { continuation.resume(throwing: SafariBridgeHealthProbeError.extensionStateUnavailable) }
                }
        }
    }

    private static func isLoopbackFixtureURL(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil else { return false }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".")
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { part in
            guard let number = Int(part), !part.isEmpty else { return false }
            return (0...255).contains(number)
        }
    }
}

import AppKit
import Darwin
import Foundation

enum SafariBridgeSpikeRunner {
    static func startIfRequested() -> Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SAFARI_BRIDGE_SPIKE"] == "1" else { return false }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let exitCode = await run()
            Darwin.exit(exitCode)
        }
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static func run() async -> Int32 {
        let trace: SafariBridgeSpikeTrace
        do {
            trace = try SafariBridgeSpikeTrace()
        } catch {
            FileHandle.standardError.write(Data("Safari bridge trace unavailable: \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
        let taskToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let transport = SafariBridgeTransport(timeout: 1.0)
        var commandStartedAt: UInt64?
        let idleConfiguration = idleConfiguration()

        do {
            guard idleConfiguration.valid else {
                try trace.write(
                    samples: [], p95Milliseconds: nil, status: "failed", reason: "invalidIdleInterval",
                    failureElapsedMilliseconds: nil,
                    additionalFields: ["idleIntervalSeconds": idleConfiguration.seconds,
                                       "acceptanceEligible": false])
                return EXIT_FAILURE
            }
            try await transport.startTask(taskToken: taskToken, registerHelperIfNeeded: true)
            let openCommand = SafariBridgeCommand(
                taskToken: taskToken,
                operation: .openTab,
                url: "https://drive.google.com/drive/my-drive")
            commandStartedAt = DispatchTime.now().uptimeNanoseconds
            let opened = try await transport.perform(openCommand)
            commandStartedAt = nil
            guard let tabId = opened.tabId, let windowId = opened.windowId else {
                throw SafariBridgeTransportFailure.unavailable(.operationFailed)
            }

            var samples: [(String, Double)] = []
            for _ in 0..<1_000 {
                let nonce = UUID().uuidString.lowercased()
                let command = SafariBridgeCommand(
                    taskToken: taskToken,
                    operation: .ping,
                    tabId: tabId,
                    windowId: windowId,
                    nonce: nonce)
                let start = DispatchTime.now().uptimeNanoseconds
                commandStartedAt = start
                _ = try await transport.perform(command)
                commandStartedAt = nil
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                samples.append((nonce, elapsed))
            }
            let ordered = samples.map(\.1).sorted()
            let p95 = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
            let latencyPassed = p95 < 50
            let safariPIDBeforeIdle = safariProcessID()
            try trace.write(
                samples: samples,
                p95Milliseconds: p95,
                status: latencyPassed ? "ok" : "failed",
                reason: latencyPassed ? nil : "p95AtOrAbove50ms",
                failureElapsedMilliseconds: nil,
                additionalFields: [
                    "idleIntervalSeconds": idleConfiguration.seconds,
                    "acceptanceEligible": idleConfiguration.acceptanceEligible,
                    "safariPIDBeforeIdle": safariPIDBeforeIdle.map { $0 as Any } ?? NSNull()
                ])
            guard latencyPassed else {
                await transport.endTask(taskToken: taskToken)
                return EXIT_FAILURE
            }

            try await Task.sleep(for: .seconds(idleConfiguration.seconds))
            let safariPIDAfterIdle = safariProcessID()
            let relaunchObserved = safariPIDBeforeIdle != nil && safariPIDAfterIdle != nil
                && safariPIDBeforeIdle != safariPIDAfterIdle
            let requireRelaunch = ProcessInfo.processInfo.environment["SAFARI_BRIDGE_SPIKE_REQUIRE_RELAUNCH"] == "1"
            let lifecycleFields: [String: Any] = [
                "idleIntervalSeconds": idleConfiguration.seconds,
                "acceptanceEligible": idleConfiguration.acceptanceEligible,
                "safariPIDBeforeIdle": safariPIDBeforeIdle.map { $0 as Any } ?? NSNull(),
                "safariPIDAfterIdle": safariPIDAfterIdle.map { $0 as Any } ?? NSNull(),
                "safariRelaunchObserved": relaunchObserved,
                "lifecycleResult": relaunchObserved ? "relaunch-observed" : "idle-only"
            ]
            if requireRelaunch && !relaunchObserved {
                try trace.write(
                    samples: [], p95Milliseconds: nil, status: "failed", reason: "safariRelaunchNotObserved",
                    failureElapsedMilliseconds: nil, additionalFields: lifecycleFields)
                await transport.endTask(taskToken: taskToken)
                return EXIT_FAILURE
            }

            let nonce = UUID().uuidString.lowercased()
            let idleCommand = SafariBridgeCommand(
                taskToken: taskToken,
                operation: .ping,
                tabId: tabId,
                windowId: windowId,
                nonce: nonce)
            let start = DispatchTime.now().uptimeNanoseconds
            commandStartedAt = start
            _ = try await transport.perform(idleCommand)
            commandStartedAt = nil
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            try trace.write(
                samples: [(nonce, elapsed)], p95Milliseconds: nil, status: "idle-ping-ok", reason: nil,
                failureElapsedMilliseconds: nil, additionalFields: lifecycleFields)
            await transport.endTask(taskToken: taskToken)
            return EXIT_SUCCESS
        } catch let failure as SafariBridgeTransportFailure {
            do {
                try trace.write(
                    samples: [], p95Milliseconds: nil, status: "unavailable", reason: failure.reason,
                    failureElapsedMilliseconds: commandStartedAt.map { elapsedMilliseconds(since: $0) },
                    additionalFields: ["idleIntervalSeconds": idleConfiguration.seconds,
                                       "acceptanceEligible": idleConfiguration.acceptanceEligible])
            } catch {
                FileHandle.standardError.write(Data("Safari bridge failure trace unavailable: \(error.localizedDescription)\n".utf8))
            }
            await transport.endTask(taskToken: taskToken)
            return EXIT_FAILURE
        } catch {
            do {
                try trace.write(
                    samples: [], p95Milliseconds: nil, status: "unavailable", reason: "operationFailed",
                    failureElapsedMilliseconds: commandStartedAt.map { elapsedMilliseconds(since: $0) },
                    additionalFields: ["idleIntervalSeconds": idleConfiguration.seconds,
                                       "acceptanceEligible": idleConfiguration.acceptanceEligible])
            } catch {
                FileHandle.standardError.write(Data("Safari bridge failure trace unavailable: \(error.localizedDescription)\n".utf8))
            }
            await transport.endTask(taskToken: taskToken)
            return EXIT_FAILURE
        }
    }

    private static func idleConfiguration() -> (seconds: UInt64, acceptanceEligible: Bool, valid: Bool) {
        guard let configured = ProcessInfo.processInfo.environment["SAFARI_BRIDGE_SPIKE_IDLE_SECONDS"] else {
            return (600, true, true)
        }
        guard let seconds = UInt64(configured), seconds <= 600 else { return (0, false, false) }
        return (seconds, seconds == 600, true)
    }

    private static func safariProcessID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
            .first?.processIdentifier
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

private extension SafariBridgeTransportFailure {
    var reason: String {
        switch self {
        case let .unavailable(reason): reason.rawValue
        case .malformedReply: SafariBridgeError.invalidPayload.rawValue
        case .taskRejected: SafariBridgeError.unauthorizedTask.rawValue
        }
    }
}

private struct SafariBridgeSpikeTrace {
    private let directory: URL
    private let traceFile: URL

    init(fileManager: FileManager = .default) throws {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appendingPathComponent("RemoteDesktopHost/Traces", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        traceFile = directory.appendingPathComponent("safari-bridge-spike-\(stamp).jsonl")
    }

    func write(
        samples: [(String, Double)],
        p95Milliseconds: Double?,
        status: String,
        reason: String?,
        failureElapsedMilliseconds: Double?,
        additionalFields: [String: Any] = [:]
    ) throws {
        let records: [[String: Any]]
        if samples.isEmpty {
            var record: [String: Any] = ["status": status]
            if let reason { record["reason"] = reason }
            if let failureElapsedMilliseconds { record["failureElapsedMilliseconds"] = failureElapsedMilliseconds }
            records = [record.merging(additionalFields) { _, new in new }]
        } else {
            records = samples.enumerated().map { index, sample in
                var record: [String: Any] = ["status": status, "nonce": sample.0, "rttMilliseconds": sample.1]
                if index == 0, let p95Milliseconds { record["p95Milliseconds"] = p95Milliseconds }
                if let reason { record["reason"] = reason }
                return record.merging(additionalFields) { _, new in new }
            }
        }
        let data = try records.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { $0 + Data([0x0A]) }
            .reduce(into: Data()) { $0.append($1) }
        let previous = FileManager.default.fileExists(atPath: traceFile.path)
            ? try Data(contentsOf: traceFile)
            : Data()
        try (previous + data).write(to: traceFile, options: .atomic)
        pruneTraces()
    }

    private func pruneTraces(fileManager: FileManager = .default) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let traces = urls.filter { url in
            guard url.lastPathComponent.hasPrefix("safari-bridge-spike-"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !contents.contains("\"status\":\"unavailable\"") && !contents.contains("\"reason\"")
        }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for old in traces.dropFirst(20) { try? fileManager.removeItem(at: old) }
    }
}

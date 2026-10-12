import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class RemoteDesktopReleaseScopeGateTests: XCTestCase {
    func testExperimentalPreferenceDefaultsOffInAnIsolatedDefaultsSuite() throws {
        let suiteName = "ReleaseScope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ComputerUseFeatureFlags.isExperimentalEnabled(in: defaults))
        defaults.set(true, forKey: ComputerUseFeatureFlags.experimentalPreferenceKey)
        XCTAssertTrue(ComputerUseFeatureFlags.isExperimentalEnabled(in: defaults))
    }

    func testFreshOutOfScopeRequestDeclinesWithoutExecutionWhileReleaseJobsAndExperimentalPass() async throws {
        let hostID = UUID().uuidString
        let peerID = UUID().uuidString
        let sessionID = UUID().uuidString
        let pairingCode = "842193"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executor = ReleaseScopeSpyExecutor()
        var experimentalEnabled = false
        let manager = HostComputerUseManager(
            experimentalEnabled: { experimentalEnabled },
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            allowsExternalServices: false)
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        defer { manager.stop() }
        manager.authorizePeer(senderID: peerID)

        let outsideRequests = [
            ("release-scope-website", "Open https://example.test and read the first paragraph."),
            ("release-scope-native", "Open Apple Notes and search for the word picnic."),
        ]
        for (id, request) in outsideRequests {
            let declined = try await submit(
                request,
                id: id,
                hostID: hostID,
                peerID: peerID,
                sessionID: sessionID,
                pairingCode: pairingCode,
                manager: manager,
                channel: channel)
            XCTAssertEqual(declined.outcome, .unableToComplete)
            XCTAssertEqual(declined.text,
                "Right now I can email files (Gmail or Apple Mail), upload files to Google Drive or Dropbox, and find flights. Turn on Experimental in Settings to try other web tasks.")
        }
        XCTAssertTrue(executor.prompts.isEmpty, "Out-of-scope requests must be rejected before executor routing.")

        let supportedRequests = [
            "Draft an email in Gmail to reviewer@example.test with subject Update.",
            "Upload the selected spreadsheet to Google Drive.",
            "Upload the selected spreadsheet to Dropbox.",
            "Email Jordan using Apple Mail.",
            "Upload the file to Google Drive and Dropbox.",
        ]
        for (index, request) in supportedRequests.enumerated() {
            let supported = try await submit(
                request,
                id: "release-scope-supported-\(index)",
                hostID: hostID,
                peerID: peerID,
                sessionID: sessionID,
                pairingCode: pairingCode,
                manager: manager,
                channel: channel)
            XCTAssertEqual(supported.outcome, .taskCompleted)
            XCTAssertEqual(supported.text, "Spy executor received the supported request.")
        }

        experimentalEnabled = true
        let experimentalRequest = "Open Apple Notes and search for the word picnic."
        let experimental = try await submit(
            experimentalRequest,
            id: "release-scope-experimental",
            hostID: hostID,
            peerID: peerID,
            sessionID: sessionID,
            pairingCode: pairingCode,
            manager: manager,
            channel: channel)
        XCTAssertEqual(experimental.outcome, .taskCompleted)
        XCTAssertEqual(executor.prompts, supportedRequests + [experimentalRequest])
    }

    private func submit(
        _ prompt: String,
        id: String,
        hostID: String,
        peerID: String,
        sessionID: String,
        pairingCode: String,
        manager: HostComputerUseManager,
        channel: LocalHostComputerUseChannel
    ) async throws -> ComputerUseTaskUpdate {
        let envelope = ComputerUseEnvelope(
            id: id,
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            kind: .prompt,
            body: prompt)
        try await channel.receiveFromClient(envelope, authenticatedSenderID: peerID)
        let received = try await channel.poll()
        XCTAssertEqual(received, [envelope])
        let accepted = try XCTUnwrap(received.first)
        XCTAssertTrue(manager.handle(accepted, channel: channel))
        try await channel.acknowledge([accepted])

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let update = try await channel.pollForClient(
                authenticatedSenderID: peerID,
                sessionID: sessionID)
                .filter({ $0.kind == .assistant })
                .compactMap({ try? ComputerUseTaskUpdate.decodeBody($0.body) })
                .first(where: { $0.taskID == id }) {
                return update
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReleaseScopeTestFailure.timedOut(id)
    }
}

@MainActor
private final class ReleaseScopeSpyExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Release scope spy"
    private(set) var prompts: [String] = []

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        prompts.append(prompt)
        return .completed("Spy executor received the supported request.")
    }
}

private enum ReleaseScopeTestFailure: Error { case timedOut(String) }

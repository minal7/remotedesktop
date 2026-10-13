import Foundation
import AppKit
import WebKit
import XCTest
import CryptoKit
#if canImport(FoundationModels) && compiler(>=6.3)
import FoundationModels
#endif
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseMobileInitiationTests: XCTestCase {

    func testNativeFileNameFilterFindsLateTargetBeforeMatchingCandidateCap() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for index in 0..<8 {
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent(String(format: "Unrelated-%02d.xlsx", index)))
        }
        let target = "ZZZ Requested Portfolio.pptx"
        try Data([99]).write(to: directory.appendingPathComponent(target))

        var fullCatalog = try ComputerUseLocalFileCatalog(taskID: "named-filter-task", approvedDirectory: directory, pageSize: 1)
        var fullPage = try fullCatalog.discover()
        var fullNames = fullPage.candidates.map(\.displayName)
        while let cursor = fullPage.nextCursor {
            fullPage = try fullCatalog.nextPage(after: cursor)
            fullNames.append(contentsOf: fullPage.candidates.map(\.displayName))
        }
        let lateTarget = try XCTUnwrap(fullNames.last)
        XCTAssertGreaterThan(fullNames.firstIndex(of: lateTarget) ?? 0, 2,
            "Use a target beyond both the raw first page and the matching candidate cap")

        let query = ComputerUseLocalFileCatalog.Query(nameContains: lateTarget)
        var boundedCatalog = try ComputerUseLocalFileCatalog(taskID: "named-filter-task", approvedDirectory: directory,
            pageSize: 1, maximumCandidates: 2, maximumEntriesScanned: 64)
        let page = try boundedCatalog.discover(query: query)
        XCTAssertEqual(page.candidates.map(\.displayName), [lateTarget])
        XCTAssertTrue(page.isComplete)
        XCTAssertNil(page.nextCursor)
    }

    func testNativeFileNameFilterFoldsCaseAndDiacriticsAndKeepsAmbiguousMatches() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for name in ["Résumé deck.pptx", "resume copy.xlsx", "Other notes.txt"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let query = ComputerUseLocalFileCatalog.Query(nameContains: "RESUME")
        var catalog = try ComputerUseLocalFileCatalog(taskID: "name-fold-task", approvedDirectory: directory, pageSize: 8)
        let page = try catalog.discover(query: query)
        XCTAssertEqual(Set(page.candidates.map(\.displayName)), Set(["Résumé deck.pptx", "resume copy.xlsx"]))
        XCTAssertEqual(page.candidates.count, 2, "Filtering must preserve multiple matches for explicit ambiguity handling")
    }

    private func syntheticEvidenceReferences(texts: [String], sources: Set<String> = []) -> [String: String] {
        var references = Dictionary(uniqueKeysWithValues: texts.enumerated().map { index, text in
            ("text:t\(index + 1)", text)
        })
        if let source = sources.sorted().first { references["source"] = source }
        return references
    }

    private func assessmentValue(_ requirements: [(String, String, String, String)],
                                 objective: String = "Complete the full user goal", constraints: String = "",
                                 workerObjective: String = "") -> JSONValue {
        .object(["objective": .string(objective), "constraints": .string(constraints),
            "workerObjective": .string(workerObjective),
            "requirements": .array(requirements.map { instruction, kind, state, evidence in
                .object(["instruction": .string(instruction), "kind": .string(kind), "state": .string(state),
                    "evidence": .string(evidence)])
            })])
    }

    private func waitForCapabilityReady(_ manager: HostComputerUseManager, timeoutIterations: Int = 200) async {
        for _ in 0 ..< timeoutIterations {
            if manager.capability.state == .ready { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the structured capability; modelState=\(String(reflecting: manager.modelState)), capability=\(manager.capability.state) (\(manager.capability.detail)), activity=\(String(reflecting: manager.activity)), needsAdditionalSetup=\(manager.needsAdditionalSetup)")
    }

    func testSetupCannotReplaceRunningOrPausedTask() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let visual = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        var calls = 0
        var release = false
        let executor = MobileInitiationReadyExecutor(beforeCompletion: {
            calls += 1
            while !release { try await Task.sleep(for: .milliseconds(10)) }
        })
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), executor: executor,
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
            visualExecutorLoader: visual, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        defer { release = true; manager.stop() }
        manager.start(pairingCode: "123456")
        manager.authorizePeer(senderID: "IOS-PEER")
        let prompt = nativeTestPrompt(id: "retained-native-task")
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { calls == 1 }
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "setup-while-running"), channel: channel))
        let runningFailure = await waitForSetupProgress(channel: channel)
        XCTAssertTrue(runningFailure.contains { $0.requestID == "setup-while-running" && $0.phase == .failed })
        guard case .working = manager.activity else { return XCTFail("Setup cannot stop the active task") }

        manager.userIntervened()
        await waitUntil { manager.activity == .paused }
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "setup-while-paused"), channel: channel))
        for _ in 0..<200 {
            if await channel.setupProgress().contains(where: { $0.requestID == "setup-while-paused" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let failures = await channel.setupProgress()
        XCTAssertEqual(failures.filter { $0.phase == .failed }.count, 2)
        XCTAssertEqual(manager.activity, .paused)
        XCTAssertEqual(visual.loadCount, 0)
        XCTAssertEqual(calls, 1)
        release = true
        let resume = ComputerUseEnvelope(senderID: "IOS-PEER", targetID: "HOST-ID", pairingCode: "123456",
            sessionID: "SESSION-1", kind: .resume,
            body: try ComputerUseControlRequest(taskID: prompt.id, revision: 1, observedHostControlEpoch: 1).encodedBody())
        XCTAssertTrue(manager.handle(resume, channel: channel))
        let completed = await waitForTaskUpdate(channel: channel, taskID: prompt.id, outcome: .taskCompleted)
        XCTAssertEqual(completed?.text, "verified")
        XCTAssertEqual(calls, 2, "Resume must still reach the same retained coordinator")
        await manager.shutdown()
    }

    func testNewPromptDuringAdditionalSetupIsTerminalWithoutExecutionOrLaterReplay() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let installer = MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt())
        let channel = MobileInitiationTestChannel()
        var calls = 0, loadStarted = false, releaseLoad = false
        let executor = MobileInitiationReadyExecutor(beforeCompletion: { calls += 1 })
        let visual = MobileInitiationVisualLoader(executor: executor, beforeLoad: {
            loadStarted = true
            while !releaseLoad { try await Task.sleep(for: .milliseconds(10)) }
        })
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
            installer: installer, visualExecutorLoader: visual,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
        defer { releaseLoad = true; manager.stop() }
        manager.start(pairingCode: "123456")
        manager.authorizePeer(senderID: "IOS-PEER")
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "setup-before-new-prompt"), channel: channel))
        await waitUntil { loadStarted }
        XCTAssertEqual(manager.capability.state, .installing,
            "The shared setup pipeline must report that setup currently owns executor activation")

        let blocked = nativeTestPrompt(id: "prompt-during-setup")
        XCTAssertTrue(manager.handle(blocked, channel: channel))
        let rejected = await waitForTaskUpdate(channel: channel, taskID: blocked.id,
            outcome: .userInterventionRequired)
        XCTAssertTrue(rejected?.text.contains("setup is still running") == true)
        XCTAssertEqual(calls, 0)

        releaseLoad = true
        _ = await waitForSetupProgress(channel: channel, terminalPhase: .ready)
        XCTAssertEqual(manager.capability.state, .ready)
        XCTAssertTrue(manager.handle(blocked, channel: channel))
        XCTAssertEqual(calls, 0, "Completing setup cannot replay a task rejected during setup")

        let fresh = nativeTestPrompt(id: "new-prompt-after-setup")
        XCTAssertTrue(manager.handle(fresh, channel: channel))
        _ = await waitForTaskUpdate(channel: channel, taskID: fresh.id, outcome: .taskCompleted)
        XCTAssertEqual(calls, 1)
        await manager.shutdown()
    }

    private func nativeTestPrompt(id: String) -> ComputerUseEnvelope {
        ComputerUseEnvelope(id: id, senderID: "IOS-PEER", targetID: "HOST-ID", pairingCode: "123456",
            sessionID: "SESSION-1", kind: .prompt, body: "Set Origin to Oslo.")
    }

    private func waitForTaskUpdate(channel: MobileInitiationTestChannel, taskID: String,
                                   outcome: ComputerUseTerminalOutcome) async -> ComputerUseTaskUpdate? {
        for _ in 0..<200 {
            if let update = await channel.taskUpdates().first(where: { $0.taskID == taskID && $0.outcome == outcome }) {
                return update
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the exact task outcome")
        return nil
    }

    func testMobileRequestInstallsModelActivatesOSAtlasAndPublishesContinuousProgress() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel(delayedFraction: 0.99)
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        let installsBeforeRequest = await modelInstaller.installCallCount()
        XCTAssertEqual(installsBeforeRequest, 0)
        XCTAssertEqual(visualLoader.loadCount, 0)

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "mobile-e2e"),
            channel: channel))
        await waitUntil {
            if case .ready = manager.modelState { return true }
            return false
        }

        let modelInstallCount = await modelInstaller.installCallCount()
        XCTAssertEqual(modelInstallCount, 1)
        XCTAssertEqual(visualLoader.loadedReceipts, [receipt])
        XCTAssertEqual(visualLoader.maximumConcurrentLoads, 1)
        XCTAssertEqual(manager.modelState, .ready(runtimeName: "OS-Atlas Pro test runtime"))
        XCTAssertEqual(manager.capability.state, .ready)
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        let failedActivations = await modelInstaller.recordedFailedActivations()
        XCTAssertEqual(successfulActivations, [receipt])
        XCTAssertTrue(failedActivations.isEmpty)

        let progress = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .ready)
        XCTAssertTrue(progress.contains {
            $0.phase == .downloadingModel
                && $0.detail.contains("2 GB of 4 GB")
        })
        XCTAssertTrue(progress.contains {
            $0.phase == .installingPackages
                && $0.fractionCompleted == 0.99
                && $0.detail.contains("OS-Atlas Pro")
        })
        let fractions = progress.compactMap(\.fractionCompleted)
        XCTAssertEqual(fractions.last, 1)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }

        // A second phone request replays readiness; it must not install or
        // activate another model process.
        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "mobile-e2e-retry"),
            channel: channel))
        await Task.yield()
        let modelInstallCountAfterRetry = await modelInstaller.installCallCount()
        XCTAssertEqual(modelInstallCountAfterRetry, 1)
        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.maximumConcurrentLoads, 1)
    }

    func testRelaunchedMobileMonitorPrunesOnlyItsSupersededCloudKitSession() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            visualExecutorLoader: MobileInitiationVisualLoader(),
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        // These arrive synchronously before the installer task gets its first
        // turn. The second request is a relaunch of IOS-PEER; IOS-PEER-2 is a
        // distinct device that must continue receiving the same setup.
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "old-monitor",
                senderID: "IOS-PEER",
                sessionID: "SESSION-OLD"),
            channel: channel))
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "new-monitor",
                senderID: "IOS-PEER",
                sessionID: "SESSION-NEW"),
            channel: channel))
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "other-device",
                senderID: "IOS-PEER-2",
                sessionID: "SESSION-OTHER"),
            channel: channel))

        await waitUntil {
            if case .ready = manager.modelState { return true }
            return false
        }
        let readyEnvelopes = await channel.setupProgressEnvelopes(phase: .ready)
        XCTAssertEqual(
            Set(readyEnvelopes.map(\.sessionID)),
            Set(["SESSION-NEW", "SESSION-OTHER"]))
        XCTAssertFalse(readyEnvelopes.contains { $0.sessionID == "SESSION-OLD" })
        let readyProgress = readyEnvelopes.compactMap {
            try? ComputerUseSetupProgress.decodeBody($0.body)
        }
        XCTAssertEqual(
            Set(readyProgress.map(\.requestID)),
            Set(["new-monitor", "other-device"]))
    }

    func testCancelledOSAtlasActivationFailsClosedAndDeactivatesRuntime() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let modelInstaller = MobileInitiationModelInstaller(
            receipt: mobileInitiationModelReceipt())
        let visualLoader = MobileInitiationVisualLoader(throwsCancellation: true)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "cancelled-activation"),
            channel: channel))
        let progress = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .failed)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertEqual(manager.capability.state, .setupRequired)
        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        XCTAssertEqual(progress.last?.phase, .failed)
        XCTAssertTrue(progress.last?.detail.contains("stopped") == true)
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        let failedActivations = await modelInstaller.recordedFailedActivations()
        XCTAssertTrue(successfulActivations.isEmpty)
        XCTAssertEqual(failedActivations, [mobileInitiationModelReceipt()])
    }

    func testFailedFirstModelLoadRequestsVerifiedInstallationRollback() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader(throwsLoadFailure: true)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "failed-first-load"),
            channel: channel))
        _ = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .failed)

        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        let failedActivations = await modelInstaller.recordedFailedActivations()
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        XCTAssertEqual(failedActivations, [receipt])
        XCTAssertTrue(successfulActivations.isEmpty)
        guard case .error = manager.modelState else {
            return XCTFail("A failed first model load must stay fail-closed")
        }
    }

    func testFreshHostWaitsForMobileSetupRequestBeforeStartingInstaller() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: installer,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let request = ComputerUseSetupRequest(requestID: "mobile-request")
        let envelope = ComputerUseEnvelope(
            senderID: "IOS-PEER",
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: "SESSION-1",
            kind: .setupRequest,
            body: try request.encodedBody())

        XCTAssertTrue(manager.handle(envelope, channel: channel))
        guard case .installing(let detail, _) = manager.modelState else {
            return XCTFail("A valid mobile setup request must start the installer pipeline")
        }
        XCTAssertEqual(detail, "Checking the local model package…")

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }
        guard case .error(let message) = manager.modelState else {
            return XCTFail("The controlled preflight failure did not arrive")
        }
        XCTAssertTrue(message.contains("at least"), message)
        let progress = await waitForSetupProgress(channel: channel)
        let fractions = progress.compactMap(\.fractionCompleted)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    func testInterruptedMobileAuthorizedInstallResumesOnHostRelaunch() async throws {
        let fixture = try makeFixture(markerPresent: true)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: installer,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }

        guard case .error(let message) = manager.modelState else {
            return XCTFail("The interrupted mobile-authorized install did not resume")
        }
        XCTAssertTrue(message.contains("at least"), message)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.marker.path),
            "A controlled failure must clear the resume marker")
    }

    func testApplicationShutdownDeactivatesVisualRuntimeBeforeReturning() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let visualLoader = MobileInitiationVisualLoader()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await manager.shutdown()

        XCTAssertEqual(visualLoader.deactivationCount, 1)
        XCTAssertEqual(manager.activity, .idle)
    }

    func testExternalServiceGuardSuppressesAllAutomaticTestHostWork() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let modelInstaller = MobileInitiationModelInstaller(
            receipt: mobileInitiationModelReceipt())
        let visualLoader = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        var channelFactoryCalls = 0
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            allowsExternalServices: false,
            channelFactory: { _ in
                channelFactoryCalls += 1
                return channel
            })

        manager.refreshModelState()
        manager.start(pairingCode: "123456")
        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "app-hosted-unit-test"),
            channel: channel))
        for _ in 0 ..< 5 { await Task.yield() }

        let modelInstalls = await modelInstaller.installCallCount()
        XCTAssertFalse(manager.allowsExternalServices)
        XCTAssertEqual(modelInstalls, 0)
        XCTAssertEqual(visualLoader.loadCount, 0)
        XCTAssertEqual(channelFactoryCalls, 0)
        XCTAssertEqual(manager.modelState, .downloadRequired)
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let marker: URL
        let ledger: URL
    }

    private func makeFixture(markerPresent: Bool) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComputerUseMobileInitiation-\(UUID().uuidString)",
            isDirectory: true)
        let root = parent.appendingPathComponent("Computer Use Model", isDirectory: true)
        let marker = root.appendingPathComponent(
            ComputerUseInstaller.interruptedInstallationMarkerName)
        let ledger = parent.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if markerPresent {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("installing\n".utf8).write(to: marker, options: .atomic)
        }
        return Fixture(parent: parent, root: root, marker: marker, ledger: ledger)
    }

    /// Fails deterministically inside installer preflight, before any file or
    /// network download, so the test can prove pipeline entry without fetching
    /// the multi-gigabyte production model.
    private var preflightFailureManifest: ComputerUseArtifactManifest {
        ComputerUseArtifactManifest(
            installationVersion: "mobile-initiation-test-v1",
            modelVariant: .pro4B,
            modelRepository: "invalid/model",
            modelRevision: "revision",
            modelArtifacts: [.init(
                kind: .textModelShard,
                fileName: "model.gguf",
                byteCount: 1,
                sha256: String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.invalid/model.gguf")!)],
            minimumMemoryBytes: .max)
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< timeoutIterations {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Computer Use state")
    }

    private func waitForSetupProgress(
        channel: MobileInitiationTestChannel,
        terminalPhase: ComputerUseSetupProgress.Phase = .failed,
        timeoutIterations: Int = 200
    ) async -> [ComputerUseSetupProgress] {
        for _ in 0 ..< timeoutIterations {
            let progress = await channel.setupProgress()
            if progress.contains(where: { $0.phase == terminalPhase }) {
                return progress
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for setup progress delivery")
        return await channel.setupProgress()
    }

    private func setupEnvelope(
        requestID: String,
        senderID: String = "IOS-PEER",
        sessionID: String = "SESSION-1"
    ) throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            senderID: senderID,
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: sessionID,
            kind: .setupRequest,
            body: try ComputerUseSetupRequest(
                requestID: requestID).encodedBody())
    }

    private func mobileInitiationModelReceipt() -> ComputerUseInstallationReceipt {
        ComputerUseInstallationReceipt(
            installationVersion: "os-atlas-mobile-test-v1",
            modelVariant: .pro4B,
            modelDirectory: "/test/OS-Atlas-Pro-4B",
            installedAt: Date(timeIntervalSince1970: 0))
    }
}

private actor MobileInitiationModelInstaller: ComputerUseModelProvisioning {
    private let receipt: ComputerUseInstallationReceipt
    private let alreadyInstalled: Bool
    private let throwsInstallFailure: Bool
    private var interrupted: Bool
    private var installs = 0
    private var clearedMarkers = 0
    private var successfulActivations: [ComputerUseInstallationReceipt] = []
    private var failedActivations: [ComputerUseInstallationReceipt] = []

    init(receipt: ComputerUseInstallationReceipt, alreadyInstalled: Bool = false, interrupted: Bool = false,
         throwsInstallFailure: Bool = false) {
        self.receipt = receipt
        self.alreadyInstalled = alreadyInstalled
        self.interrupted = interrupted
        self.throwsInstallFailure = throwsInstallFailure
    }

    func currentInstallation() -> ComputerUseInstallationReceipt? { alreadyInstalled ? receipt : nil }

    func interruptedInstallationExists() -> Bool { interrupted }

    func clearInterruptedInstallationMarker() {
        clearedMarkers += 1
        interrupted = false
    }

    func recordRuntimeActivationSuccess(
        for receipt: ComputerUseInstallationReceipt
    ) {
        successfulActivations.append(receipt)
    }

    func restorePreviousInstallation(
        afterFailedActivationOf receipt: ComputerUseInstallationReceipt
    ) {
        failedActivations.append(receipt)
    }

    func install(
        progress: @MainActor @Sendable @escaping (ComputerUseInstaller.Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt {
        installs += 1
        if throwsInstallFailure { throw CocoaError(.fileWriteOutOfSpace) }
        let updates: [ComputerUseInstaller.Update] = [
            .init(
                phase: .preparing,
                fraction: 0,
                detail: "Checking model storage…"),
            .init(
                phase: .downloadingModel,
                fraction: 0.5,
                detail: "Downloading OS-Atlas Pro… 2 GB of 4 GB"),
            .init(
                phase: .verifying,
                fraction: 0.96,
                detail: "Verifying OS-Atlas Pro…"),
            .init(
                phase: .ready,
                fraction: 1,
                detail: "OS-Atlas Pro is installed"),
        ]
        for update in updates {
            try Task.checkCancellation()
            await progress(update)
        }
        return receipt
    }

    func installCallCount() -> Int { installs }
    func clearedMarkerCount() -> Int { clearedMarkers }
    func recordedSuccessfulActivations() -> [ComputerUseInstallationReceipt] {
        successfulActivations
    }
    func recordedFailedActivations() -> [ComputerUseInstallationReceipt] {
        failedActivations
    }
}

@MainActor
private final class MobileInitiationVisualLoader: ComputerUseVisualExecutorLoading {
    private(set) var loadedReceipts: [ComputerUseInstallationReceipt] = []
    private(set) var deactivationCount = 0
    private(set) var maximumConcurrentLoads = 0
    private var activeLoads = 0
    private let throwsCancellation: Bool
    private let throwsLoadFailure: Bool
    private let executor: (any ComputerUseExecuting)?
    private let beforeLoad: @MainActor () async throws -> Void

    var loadCount: Int { loadedReceipts.count }

    init(
        throwsCancellation: Bool = false,
        throwsLoadFailure: Bool = false,
        executor: (any ComputerUseExecuting)? = nil,
        beforeLoad: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.throwsCancellation = throwsCancellation
        self.throwsLoadFailure = throwsLoadFailure
        self.executor = executor
        self.beforeLoad = beforeLoad
    }

    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting {
        loadedReceipts.append(receipt)
        activeLoads += 1
        maximumConcurrentLoads = max(maximumConcurrentLoads, activeLoads)
        defer { activeLoads -= 1 }
        progress("Starting OS-Atlas Pro test runtime…")
        try await beforeLoad()
        if throwsCancellation { throw CancellationError() }
        if throwsLoadFailure { throw CocoaError(.fileReadCorruptFile) }
        return executor ?? MobileInitiationReadyExecutor(runtimeName: "OS-Atlas Pro test runtime")
    }

    func deactivate() async {
        deactivationCount += 1
    }
}

@MainActor
private final class MobileInitiationReadyExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName: String
    private let beforeCompletion: @MainActor () async throws -> Void

    init(runtimeName: String = "Test local model",
         beforeCompletion: @escaping @MainActor () async throws -> Void = {}) {
        self.runtimeName = runtimeName
        self.beforeCompletion = beforeCompletion
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await beforeCompletion()
        return .completed("verified")
    }
}

private actor MobileInitiationTestChannel: HostComputerUseChannel {
    private var sent: [ComputerUseEnvelope] = []
    private let delayedFraction: Double?

    init(delayedFraction: Double? = nil) {
        self.delayedFraction = delayedFraction
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        if kind == .setupProgress,
           let delayedFraction,
           let progress = try? ComputerUseSetupProgress.decodeBody(body),
           progress.fractionCompleted == delayedFraction {
            try await Task.sleep(for: .milliseconds(50))
        }
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: "HOST-ID",
            targetID: explicitTargetID ?? "IOS-PEER",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "SESSION-1",
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func setupProgress() -> [ComputerUseSetupProgress] {
        sent.compactMap { envelope in
            guard envelope.kind == .setupProgress else { return nil }
            return try? ComputerUseSetupProgress.decodeBody(envelope.body)
        }
    }

    func taskUpdates() -> [ComputerUseTaskUpdate] {
        sent.compactMap { envelope in
            guard envelope.kind == .assistant else { return nil }
            return try? ComputerUseTaskUpdate.decodeBody(envelope.body)
        }
    }

    func approvalRequests() -> [ComputerUseApprovalRequest] {
        sent.compactMap { $0.kind == .approvalRequest ? try? ComputerUseApprovalRequest.decodeBody($0.body) : nil }
    }

    func messages() -> [ComputerUseEnvelope] { sent }

    func setupProgressEnvelopes(
        phase: ComputerUseSetupProgress.Phase
    ) -> [ComputerUseEnvelope] {
        sent.filter { envelope in
            guard envelope.kind == .setupProgress,
                  let progress = try? ComputerUseSetupProgress.decodeBody(
                    envelope.body) else {
                return false
            }
            return progress.phase == phase
        }
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseMobileInitiationTests: XCTestCase {
    func testMobileRequestInstallsModelActivatesOSAtlasAndPublishesContinuousProgress() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader()
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let channel = MobileInitiationTestChannel(delayedFraction: 0.99)
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: macControlInstaller,
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        await waitForStatusCheck(macControlInstaller)
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

        let helperInstallCount = await macControlInstaller.installCallCount()
        let modelInstallCount = await modelInstaller.installCallCount()
        XCTAssertEqual(helperInstallCount, 1)
        XCTAssertEqual(modelInstallCount, 1)
        XCTAssertEqual(visualLoader.loadedReceipts, [receipt])
        XCTAssertEqual(visualLoader.maximumConcurrentLoads, 1)
        XCTAssertEqual(manager.modelState, .ready(runtimeName: "OS-Atlas Pro test runtime"))
        XCTAssertEqual(manager.capability.state, .ready)

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
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: MobileInitiationVisualLoader(),
            executorComposer: { _, visualFallback in visualFallback },
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
        let composerRecorder = MobileInitiationComposerRecorder()
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in
                await composerRecorder.recordCall()
                return visualFallback
            },
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
        let composerCalls = await composerRecorder.callCount()
        XCTAssertEqual(composerCalls, 0)
        XCTAssertEqual(progress.last?.phase, .failed)
        XCTAssertTrue(progress.last?.detail.contains("stopped") == true)
    }

    func testFreshHostWaitsForMobileSetupRequestBeforeStartingInstaller() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        await waitForStatusCheck(macControlInstaller)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let installCallsBeforeRequest = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCallsBeforeRequest, 0)

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
        XCTAssertEqual(detail, "Checking this Mac…")

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }
        guard case .error(let message) = manager.modelState else {
            return XCTFail("The controlled preflight failure did not arrive")
        }
        XCTAssertTrue(message.contains("at least"), message)
        let installCallsAfterRequest = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCallsAfterRequest, 1)

        let progress = await waitForSetupProgress(channel: channel)
        let helperProgress = progress.filter {
            $0.phase == .installingPackages
                && $0.detail.contains("Downloading Mac control")
        }
        XCTAssertFalse(helperProgress.isEmpty)
        XCTAssertTrue(helperProgress.contains {
            $0.detail.contains("250 bytes of 1,000 bytes")
        })
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
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .ready(mobileInitiationMacControlReceipt))
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
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
        let resumedModelInstallCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(resumedModelInstallCalls, 1)
    }

    func testDurablePartialHelperDownloadResumesWithoutAnotherTap() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .downloadPresent(
                downloadedByteCount: 250,
                totalByteCount: 1_000))
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }

        let resumedHelperInstallCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(resumedHelperInstallCalls, 1)
        guard case .error(let message) = manager.modelState else {
            return XCTFail("The resumed helper did not continue into model preflight")
        }
        XCTAssertTrue(message.contains("at least"), message)
    }

    func testLoadedModelIsNotAdvertisedReadyWithoutHelperReceipt() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: MobileInitiationReadyExecutor(),
            installer: ComputerUseInstaller(
                manifest: preflightFailureManifest,
                rootDirectory: fixture.root),
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await waitForStatusCheck(macControlInstaller)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertEqual(manager.capability.state, .setupRequired)
        let installCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCalls, 0)
    }

    func testApplicationShutdownDeactivatesVisualRuntimeBeforeReturning() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let visualLoader = MobileInitiationVisualLoader()
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
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
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .ready(mobileInitiationMacControlReceipt))
        let visualLoader = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        var channelFactoryCalls = 0
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: macControlInstaller,
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
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

        let statusChecks = await macControlInstaller.statusCheckCount()
        let helperInstalls = await macControlInstaller.installCallCount()
        let modelInstalls = await modelInstaller.installCallCount()
        XCTAssertFalse(manager.allowsExternalServices)
        XCTAssertEqual(statusChecks, 0)
        XCTAssertEqual(helperInstalls, 0)
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

    private func waitForStatusCheck(
        _ installer: MobileInitiationMacControlInstaller,
        timeoutIterations: Int = 200
    ) async {
        for _ in 0 ..< timeoutIterations {
            if await installer.statusCheckCount() > 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the read-only helper status check")
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

private let mobileInitiationMacControlReceipt = MacControlMCPInstallationReceipt(
    packageVersion: "test",
    archiveSHA256: "test",
    appBundlePath: "/test/MacControlMCP.app",
    binaryPath: "/test/MacControlMCP.app/Contents/MacOS/MacControlMCP",
    bundleIdentifier: "dev.macmcp.server",
    teamIdentifier: "TEST",
    signingIdentity: "Test Identity",
    installedAt: Date(timeIntervalSince1970: 0))

private actor MobileInitiationMacControlInstaller: MacControlMCPProvisioning {
    private var status: MacControlMCPInstaller.DurableStatus
    private var installs = 0
    private var statusChecks = 0

    init(status: MacControlMCPInstaller.DurableStatus) {
        self.status = status
    }

    func durableStatus() async -> MacControlMCPInstaller.DurableStatus {
        statusChecks += 1
        return status
    }

    func install(
        progress: @MainActor @Sendable @escaping (MacControlMCPInstaller.Update) -> Void
    ) async throws -> MacControlMCPInstallationReceipt {
        installs += 1
        let updates: [MacControlMCPInstaller.Update] = [
            .init(
                phase: .preparing,
                fraction: 0,
                downloadedByteCount: 0,
                totalByteCount: 1_000,
                detail: "Preparing Mac control…"),
            .init(
                phase: .downloading,
                fraction: 0.25,
                downloadedByteCount: 250,
                totalByteCount: 1_000,
                detail: "Downloading Mac control… 250 bytes of 1,000 bytes"),
            .init(
                phase: .downloading,
                fraction: 0.75,
                downloadedByteCount: 750,
                totalByteCount: 1_000,
                detail: "Downloading Mac control… 750 bytes of 1,000 bytes"),
            .init(
                phase: .ready,
                fraction: 1,
                downloadedByteCount: 1_000,
                totalByteCount: 1_000,
                detail: "Mac control is installed"),
        ]
        for update in updates {
            await progress(update)
        }
        status = .ready(mobileInitiationMacControlReceipt)
        return mobileInitiationMacControlReceipt
    }

    func installCallCount() -> Int { installs }
    func statusCheckCount() -> Int { statusChecks }
}

private actor MobileInitiationModelInstaller: ComputerUseModelProvisioning {
    private let receipt: ComputerUseInstallationReceipt
    private var installs = 0
    private var clearedMarkers = 0

    init(receipt: ComputerUseInstallationReceipt) {
        self.receipt = receipt
    }

    func currentInstallation() -> ComputerUseInstallationReceipt? { nil }

    func interruptedInstallationExists() -> Bool { false }

    func clearInterruptedInstallationMarker() {
        clearedMarkers += 1
    }

    func install(
        progress: @MainActor @Sendable @escaping (ComputerUseInstaller.Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt {
        installs += 1
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
}

@MainActor
private final class MobileInitiationVisualLoader: ComputerUseVisualExecutorLoading {
    private(set) var loadedReceipts: [ComputerUseInstallationReceipt] = []
    private(set) var deactivationCount = 0
    private(set) var maximumConcurrentLoads = 0
    private var activeLoads = 0
    private let throwsCancellation: Bool

    var loadCount: Int { loadedReceipts.count }

    init(throwsCancellation: Bool = false) {
        self.throwsCancellation = throwsCancellation
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
        if throwsCancellation { throw CancellationError() }
        return MobileInitiationReadyExecutor(
            runtimeName: "OS-Atlas Pro test runtime")
    }

    func deactivate() async {
        deactivationCount += 1
    }
}

private actor MobileInitiationComposerRecorder {
    private var calls = 0

    func recordCall() { calls += 1 }
    func callCount() -> Int { calls }
}

@MainActor
private final class MobileInitiationReadyExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName: String

    init(runtimeName: String = "Test local model") {
        self.runtimeName = runtimeName
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        .completed("Done")
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

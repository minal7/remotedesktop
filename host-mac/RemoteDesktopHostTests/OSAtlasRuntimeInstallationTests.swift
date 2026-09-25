import Foundation
import AppKit
import XCTest
@testable import RemoteDesktopHost

actor PreparationRejectingLauncher: OSAtlasLlamaServerLaunching {
    private(set) var calls = 0
    func launch(configuration: OSAtlasLlamaLaunchConfiguration) async throws -> any OSAtlasLlamaServerProcess {
        calls += 1
        throw OSAtlasLlamaRuntimeError.serverFailedToStart
    }
}

final class OSAtlasRuntimeInstallationTests: XCTestCase {
    @MainActor
    func testOptInBrowserPackageResolutionWaitsForMCPGap() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native browser continuation through deferred production package resolution")
        }
        for scenario in ["absent", "broken", "available"] {
            let fixture = try makeFaraFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let info: [String: Any] = ["CFBundleIdentifier": "test.fara.demand", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: fixture.bundleDirectory.appendingPathComponent("Contents/Info.plist"))
            if scenario == "broken" {
                try FileManager.default.removeItem(at: fixture.modelDirectory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName))
            }
            let launcher = PreparationRejectingLauncher(), runtime = OSAtlasLlamaRuntime(launcher: launcher)
            let loader = OSAtlasVisualExecutorLoader(resolver: .init(manifest: fixture.manifest),
                bundle: try XCTUnwrap(Bundle(url: fixture.bundleDirectory)), runtime: runtime,
                faraJournalDirectory: fixture.root.appendingPathComponent("task"))
            let executor = try loader.prepareBrowser(receipt: scenario == "absent" ? nil : fixture.receipt)
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                browserNavigationTask: .init(browser: browser, journalDirectory: fixture.root.appendingPathComponent("browser")))
            var toolCalls = 0, identity: String?
            let propose: ComputerUseFaraBrowserExecutor.ProposeUsingTools = { input, observation in
                XCTAssertEqual(input.goal, "Browse documentation.")
                XCTAssertEqual(input.history.count, toolCalls)
                guard case .initial(let initial) = observation else { throw ComputerUseFaraBrowserExecutor.Failure.browserChanged }
                if let identity { XCTAssertEqual(initial.sessionIdentity, identity) }
                else { identity = initial.sessionIdentity }
                toolCalls += 1
                if toolCalls > 1 { return .noProposal }
                let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"ask_user_question","question":"Which project?"}}</tool_call>"#
                return .proposal(try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response)))
            }
            let first = try await tools.withOwnedBrowserToolProposals(taskID: "task", propose: propose) {
                try await executor.execute(taskID: "task", prompt: "Browse documentation.", trustedUserPrompt: "Browse documentation.", tools: tools, progress: { _ in })
            }
            XCTAssertEqual(first, .clarificationRequired("Which project?"))
            let before = await launcher.calls
            XCTAssertEqual(before, 0, "\(scenario) package cannot be required while tools suffice")
            let pending = try XCTUnwrap(executor.clarification(taskID: "task"))
            let goal = try pending.goal.answering(pending.question, with: "Swift")
            let window = try XCTUnwrap(NSApp.keyWindow?.windowNumber)
            do {
                _ = try await tools.withOwnedBrowserToolProposals(taskID: "task", propose: propose) {
                    try await executor.continueClarification(taskID: "answer", originatingTaskID: "task", goal: goal, progress: { _ in })
                }
                XCTFail("The deliberately unavailable model cannot produce an action")
            } catch {
                if scenario == "absent" { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .visualModelUnavailable) }
                else if scenario == "broken" { XCTAssertTrue(error is OSAtlasRuntimeInstallationError, String(reflecting: error)) }
                else { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .serverFailedToStart) }
            }
            let after = await launcher.calls
            XCTAssertEqual(after, scenario == "available" ? 1 : 0)
            XCTAssertEqual(toolCalls, 2); XCTAssertEqual(NSApp.keyWindow?.windowNumber, window)
            XCTAssertTrue(tools.matchesOwnedBrowserAgentSession(taskID: "task", identity: try XCTUnwrap(identity)))
            XCTAssertFalse(tools.hasOwnedBrowserToolProposals)
            await loader.deactivate()
        }
    }

    @MainActor
    func testPreparingFaraBrowserDoesNotActivateModelButSetupStillDoes() async throws {
        let fixture = try makeFaraFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.fara.prepare", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: fixture.bundleDirectory.appendingPathComponent("Contents/Info.plist"))
        let launcher = PreparationRejectingLauncher()
        let runtime = OSAtlasLlamaRuntime(launcher: launcher)
        let loader = OSAtlasVisualExecutorLoader(resolver: .init(manifest: fixture.manifest),
            bundle: try XCTUnwrap(Bundle(url: fixture.bundleDirectory)), runtime: runtime,
            faraJournalDirectory: fixture.root.appendingPathComponent("journal"))
        var prepared: ComputerUsePreparedVisualExecutor?, failure: Error?
        do { prepared = try await loader.prepare(receipt: fixture.receipt, progress: { _ in }) }
        catch { failure = error }
        let preparationLaunches = await launcher.calls
        XCTAssertNil(failure, "Preparing a tool-capable browser must not warm the computer-use model")
        XCTAssertTrue(prepared?.executor is ComputerUseDefaultBrowserExecutor)
        XCTAssertEqual(prepared?.runtimeWasActivated, false)
        XCTAssertEqual(preparationLaunches, 0)
        let defaultBrowser = try loader.prepareDefaultBrowser(receipt: fixture.receipt)
        XCTAssertTrue(defaultBrowser is ComputerUseDefaultBrowserExecutor)
        let defaultBrowserLaunches = await launcher.calls
        XCTAssertEqual(defaultBrowserLaunches, 0)
        do {
            _ = try await loader.load(receipt: fixture.receipt, progress: { _ in })
            XCTFail("Setup must actually attempt model activation")
        } catch { }
        let setupLaunches = await launcher.calls
        XCTAssertEqual(setupLaunches, preparationLaunches + 1)
        await loader.deactivate()
    }

    func testHoloReceiptResolvesOnlyItsPinnedTwoFilePackage() throws {
        let fixture = try makeTrainedFixture(.holo31)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try OSAtlasRuntimeInputResolver(manifest: fixture.manifest).resolveAvailablePackage(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory)
        guard case .holo(let inputs) = package else { return XCTFail("Holo must resolve to its own model family") }
        XCTAssertEqual(inputs.modelURL.lastPathComponent, ComputerUseHoloRuntimeInputs.modelFileName)
        XCTAssertEqual(inputs.projectorURL.lastPathComponent, ComputerUseHoloRuntimeInputs.projectorFileName)
        XCTAssertEqual(inputs.llamaServerURL, fixture.runtimeDirectory.appendingPathComponent("llama-server"))
    }

    func testHoloResolverRejectsChangedReceiptsArtifactsAndExecutableScope() throws {
        for scenario in ["stale", "variant", "missing model", "missing projector", "truncated", "symlink model", "symlink projector", "external runtime", "extra artifact", "wrong kind"] {
            let fixture = try makeTrainedFixture(.holo31)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var receipt = fixture.receipt, manifest = fixture.manifest, runtime = fixture.runtimeDirectory
            let model = fixture.modelDirectory.appendingPathComponent(ComputerUseHoloRuntimeInputs.modelFileName)
            let projector = fixture.modelDirectory.appendingPathComponent(ComputerUseHoloRuntimeInputs.projectorFileName)
            switch scenario {
            case "stale", "variant": receipt = .init(installationVersion: scenario == "stale" ? "old" : manifest.installationVersion,
                modelVariant: scenario == "variant" ? .fara15_4B : .holo31_4B, modelDirectory: fixture.modelDirectory.path, installedAt: Date())
            case "missing model": try FileManager.default.removeItem(at: model)
            case "missing projector": try FileManager.default.removeItem(at: projector)
            case "truncated": try Data([1]).write(to: model)
            case "symlink model", "symlink projector":
                let target = scenario == "symlink model" ? model : projector, external = fixture.root.appendingPathComponent("outside.gguf")
                try FileManager.default.moveItem(at: target, to: external)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            case "external runtime": runtime = fixture.modelDirectory
            case "extra artifact": manifest = self.manifest(from: manifest, artifacts: manifest.modelArtifacts + [manifest.modelArtifacts[0]])
            case "wrong kind":
                let a = manifest.modelArtifacts[0]
                manifest = self.manifest(from: manifest, artifacts: [.init(kind: .nativeTextPlannerModel, fileName: a.fileName, byteCount: a.byteCount, sha256: a.sha256, downloadURL: a.downloadURL), manifest.modelArtifacts[1]])
            default: break
            }
            XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(manifest: manifest).resolveAvailablePackage(receipt: receipt,
                runtimeDirectoryURL: runtime, enclosingBundleURL: fixture.bundleDirectory), scenario)
        }
    }

    func testHoloManifestRetainsDataPinsAndBundledAttributionWithoutChangingDefault() throws {
        let manifest = ComputerUseArtifactManifest.holo31
        XCTAssertEqual(ComputerUseArtifactManifest.current, .fara15)
        XCTAssertEqual(manifest.minimumMemoryBytes, 12 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(manifest.modelArtifacts.map(\.byteCount), [3_066_386_464, 672_424_256])
        XCTAssertEqual(manifest.modelArtifacts.map(\.sha256), ["cfdd26e8e9ee34de0c052ea68fb5c61dd8f34986fa3e1b631e2bab6ab1b44ac9", "4eca6e6633c5384c4f6e220e1076fd6b96c53bc75baf421c553a8d8ba9649f5f"])
        XCTAssertTrue(manifest.modelArtifacts.allSatisfy { $0.downloadURL.path.contains("/resolve/" + manifest.modelRevision + "/") })
        XCTAssertEqual(Set(manifest.legalArtifacts.map(\.fileName)), Set(["HOLO-NOTICE.txt", "QWEN35-APACHE-2.0-LICENSE.txt", "LLAMA-CPP-MIT-LICENSE.txt"]))
        for artifact in manifest.legalArtifacts {
            let url = try XCTUnwrap(ComputerUseArtifactManifest.bundledLegalDocumentURL(artifact))
            XCTAssertEqual(try Data(contentsOf: url).count, Int(artifact.byteCount))
        }
    }

    func testFaraReceiptResolvesCurrentTwoFilePackageWithoutLegacyModels() throws {
        let fixture = try makeFaraFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = OSAtlasRuntimeInputResolver(manifest: fixture.manifest)
        let package = try resolver.resolveAvailablePackage(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory)
        guard case .fara(let inputs) = package else { return XCTFail("The current package must activate Fara.") }
        XCTAssertEqual(inputs.modelURL, fixture.modelDirectory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName))
        XCTAssertEqual(inputs.projectorURL, fixture.modelDirectory.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName))
        XCTAssertEqual(inputs.llamaServerURL, fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.modelDirectory.path)),
            Set([ComputerUseFaraRuntimeInputs.modelFileName, ComputerUseFaraRuntimeInputs.projectorFileName]))
    }

    func testFaraResolverRejectsStaleReceiptMissingChangedSymlinkedDataAndExternalRuntime() throws {
        for scenario in ["stale", "variant", "missing", "truncated", "symlink", "external-runtime", "extra-artifact"] {
            let fixture = try makeFaraFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var receipt = fixture.receipt
            var manifest = fixture.manifest
            var runtime = fixture.runtimeDirectory
            let model = fixture.modelDirectory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName)
            switch scenario {
            case "stale", "variant":
                receipt = .init(installationVersion: scenario == "stale" ? "old" : manifest.installationVersion,
                    modelVariant: scenario == "variant" ? .pro4B : .fara15_4B,
                    modelDirectory: fixture.modelDirectory.path, installedAt: Date())
            case "missing": try FileManager.default.removeItem(at: model)
            case "truncated": try Data([1]).write(to: model)
            case "symlink":
                let external = fixture.root.appendingPathComponent("outside.gguf")
                try FileManager.default.moveItem(at: model, to: external)
                try FileManager.default.createSymbolicLink(at: model, withDestinationURL: external)
            case "external-runtime": runtime = fixture.modelDirectory
            case "extra-artifact":
                manifest = self.manifest(from: manifest, artifacts: manifest.modelArtifacts + [manifest.modelArtifacts[0]])
            default: break
            }
            XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(manifest: manifest).resolveAvailablePackage(
                receipt: receipt, runtimeDirectoryURL: runtime, enclosingBundleURL: fixture.bundleDirectory), scenario)
        }
    }

    private func makeFaraFixture() throws -> Fixture {
        try makeTrainedFixture(.fara15)
    }

    private func makeTrainedFixture(_ selected: ComputerUseArtifactManifest) throws -> Fixture {
        let fixture = try makeFixture()
        for artifact in fixture.manifest.modelArtifacts {
            try FileManager.default.removeItem(at: fixture.modelDirectory.appendingPathComponent(artifact.fileName))
        }
        let artifacts = selected.modelArtifacts.map {
            ComputerUseArtifactManifest.DownloadableArtifact(kind: $0.kind, fileName: $0.fileName,
                byteCount: 3, sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                downloadURL: $0.downloadURL)
        }
        for artifact in artifacts { try Data([1, 2, 3]).write(to: fixture.modelDirectory.appendingPathComponent(artifact.fileName)) }
        let manifest = ComputerUseArtifactManifest(installationVersion: "trained-fixture", modelVariant: selected.modelVariant,
            modelRepository: "test/fara", modelRevision: "test-revision", modelArtifacts: artifacts, minimumMemoryBytes: 0)
        return Fixture(root: fixture.root, bundleDirectory: fixture.bundleDirectory,
            runtimeDirectory: fixture.runtimeDirectory, modelDirectory: fixture.modelDirectory, manifest: manifest,
            receipt: .init(installationVersion: manifest.installationVersion, modelVariant: selected.modelVariant,
                modelDirectory: fixture.modelDirectory.path, installedAt: Date()))
    }

    func testNativeTextReceiptResolvesWithoutVisualArtifactsAndCannotBecomeVisualPackage() throws {
        let fixture = try makeNativeTextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = OSAtlasRuntimeInputResolver(manifest: fixture.manifest)
        let inputs = try resolver.resolveNativeText(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory)
        XCTAssertEqual(inputs.modelURL, fixture.modelDirectory.appendingPathComponent("Qwen3.5-4B-Q4_K_M.gguf"))
        XCTAssertEqual(inputs.llamaServerURL, fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.modelDirectory.path),
                       ["Qwen3.5-4B-Q4_K_M.gguf"])
        XCTAssertThrowsError(try resolver.resolve(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory)) {
            XCTAssertEqual($0 as? OSAtlasRuntimeInstallationError, .proModelRequired)
        }
    }

    func testNativeTextResolverRejectsStaleReceiptChangedDataSymlinksAndExternalExecutable() throws {
        let fixture = try makeNativeTextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = OSAtlasRuntimeInputResolver(manifest: fixture.manifest)
        let stale = ComputerUseInstallationReceipt(installationVersion: "old", modelVariant: .nativeText4B,
            modelDirectory: fixture.modelDirectory.path, installedAt: Date())
        XCTAssertThrowsError(try resolver.resolveNativeText(receipt: stale,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory))
        XCTAssertThrowsError(try resolver.resolveNativeText(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.modelDirectory, enclosingBundleURL: fixture.bundleDirectory))
        let file = fixture.modelDirectory.appendingPathComponent("Qwen3.5-4B-Q4_K_M.gguf")
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try resolver.resolveNativeText(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory))
        try FileManager.default.removeItem(at: file)
        let external = fixture.root.appendingPathComponent("outside.gguf")
        try Data([1, 2, 3]).write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertThrowsError(try resolver.resolveNativeText(receipt: fixture.receipt,
            runtimeDirectoryURL: fixture.runtimeDirectory, enclosingBundleURL: fixture.bundleDirectory))
    }

    private func makeNativeTextFixture() throws -> Fixture {
        let fixture = try makeFixture()
        for artifact in fixture.manifest.modelArtifacts {
            try FileManager.default.removeItem(at: fixture.modelDirectory.appendingPathComponent(artifact.fileName))
        }
        let fileName = "Qwen3.5-4B-Q4_K_M.gguf"
        try Data([1, 2, 3]).write(to: fixture.modelDirectory.appendingPathComponent(fileName))
        let manifest = ComputerUseArtifactManifest(installationVersion: "native-text-fixture", modelVariant: .nativeText4B,
            modelRepository: "test/native-text", modelRevision: "test-revision",
            modelArtifacts: [.init(kind: .nativeTextPlannerModel, fileName: fileName, byteCount: 3,
                sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                downloadURL: URL(string: "https://example.invalid/" + fileName)!)], minimumMemoryBytes: 0)
        let receipt = ComputerUseInstallationReceipt(installationVersion: manifest.installationVersion,
            modelVariant: .nativeText4B, modelDirectory: fixture.modelDirectory.path, installedAt: Date())
        return Fixture(root: fixture.root, bundleDirectory: fixture.bundleDirectory,
            runtimeDirectory: fixture.runtimeDirectory, modelDirectory: fixture.modelDirectory,
            manifest: manifest, receipt: receipt)
    }

    func testVerifiedProReceiptResolvesOnlyDataFilesAndBundledExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let inputs = try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)

        XCTAssertEqual(inputs.variant, .pro4B)
        XCTAssertEqual(
            inputs.modelFirstSplitURL,
            fixture.modelDirectory.appendingPathComponent(
                fixture.manifest.modelArtifacts[0].fileName))
        XCTAssertEqual(
            inputs.multimodalProjectorURL,
            fixture.modelDirectory.appendingPathComponent(
                fixture.manifest.modelArtifacts[2].fileName))
        XCTAssertEqual(
            inputs.llamaServerURL,
            fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertTrue(inputs.llamaServerURL.path.hasPrefix(
            fixture.bundleDirectory.path + "/"))
    }

    func testMultiModelPackageResolvesVisualAndSemanticInputsFromManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let package = try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolvePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)

        XCTAssertEqual(
            package.visualInputs.modelFirstSplitURL,
            fixture.modelDirectory.appendingPathComponent(
                fixture.manifest.modelArtifacts[0].fileName))
        XCTAssertEqual(
            package.semanticRouterModelURL,
            fixture.modelDirectory.appendingPathComponent(
                fixture.manifest.modelArtifacts[3].fileName))
    }

    func testAvailablePackageSelectsCurrentVisualOnlyReleaseShape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let visualManifest = manifest(
            from: fixture.manifest,
            artifacts: Array(fixture.manifest.modelArtifacts.dropLast()))

        let package = try OSAtlasRuntimeInputResolver(
            manifest: visualManifest).resolveAvailablePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)

        guard case .visualOnly(let inputs) = package else {
            return XCTFail("A visual-only manifest must retain the Foundation + OS-Atlas activation path.")
        }
        XCTAssertEqual(inputs.variant, .pro4B)
        XCTAssertEqual(
            inputs.multimodalProjectorURL.lastPathComponent,
            "mmproj-os-atlas-pro-4b-f16.gguf")
    }

    func testAvailablePackageSelectsTwoModelShapeOnlyWithOneSemanticArtifact()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let package = try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolveAvailablePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)

        guard case .visualAndSemantic(let installation) = package else {
            return XCTFail("One pinned semantic artifact must select the two-model activation path.")
        }
        XCTAssertEqual(
            installation.semanticRouterModelURL.lastPathComponent,
            "semantic-router-q4_k_m.gguf")
    }

    func testMultiModelPackageRequiresExactlyOneSemanticArtifact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missingManifest = manifest(
            from: fixture.manifest,
            artifacts: Array(fixture.manifest.modelArtifacts.dropLast()))
        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: missingManifest).resolvePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .invalidReceipt)
        }

        let duplicate = ComputerUseArtifactManifest.DownloadableArtifact(
            kind: .semanticRouterModel,
            fileName: "semantic-router-copy.gguf",
            byteCount: 6,
            sha256: String(repeating: "e", count: 64),
            downloadURL: URL(string:
                "https://example.invalid/semantic-router-copy.gguf")!)
        try Data(repeating: 5, count: 6).write(to:
            fixture.modelDirectory.appendingPathComponent(duplicate.fileName))
        let duplicateManifest = manifest(
            from: fixture.manifest,
            artifacts: fixture.manifest.modelArtifacts + [duplicate])
        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: duplicateManifest).resolvePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .invalidReceipt)
        }

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: duplicateManifest).resolveAvailablePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .invalidReceipt)
        }
    }

    func testMultiModelPackageFailsWhenPinnedSemanticFileIsMissing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let semantic = try XCTUnwrap(fixture.manifest.modelArtifacts.last)
        try FileManager.default.removeItem(at:
            fixture.modelDirectory.appendingPathComponent(semantic.fileName))

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolvePackage(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .missingModelArtifact(semantic.fileName))
        }
    }

    func testLegacyVisualOnlyResolveAPIStaysCompatible() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let visualManifest = manifest(
            from: fixture.manifest,
            artifacts: Array(fixture.manifest.modelArtifacts.dropLast()))

        let inputs = try OSAtlasRuntimeInputResolver(
            manifest: visualManifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)

        XCTAssertEqual(inputs.variant, .pro4B)
        XCTAssertEqual(
            inputs.multimodalProjectorURL.lastPathComponent,
            "mmproj-os-atlas-pro-4b-f16.gguf")
    }

    func testBaseReceiptIsRejectedBeforeRuntimeLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseReceipt = ComputerUseInstallationReceipt(
            installationVersion: fixture.receipt.installationVersion,
            modelVariant: .base4B,
            modelDirectory: fixture.receipt.modelDirectory,
            installedAt: fixture.receipt.installedAt)

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: baseReceipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .proModelRequired)
        }
    }

    func testMissingModelShardFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = fixture.modelDirectory.appendingPathComponent(
            fixture.manifest.modelArtifacts[1].fileName)
        try FileManager.default.removeItem(at: missing)

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .missingModelArtifact(missing.lastPathComponent))
        }
    }

    func testRuntimeOutsideSignedBundleFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unrelatedBundle = fixture.root.appendingPathComponent(
            "Other.app",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedBundle,
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: unrelatedBundle)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .bundledRuntimeMissing)
        }
    }

    func testMissingBundledDependencyFailsBeforeProcessLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missingName = "libmtmd.0.dylib"
        try FileManager.default.removeItem(at:
            fixture.runtimeDirectory.appendingPathComponent(missingName))

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .bundledRuntimeIncomplete(missingName))
        }
    }

    func testBundledCompatibilitySymlinkToInternalRegularFileIsAccepted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let compatibilityName = "libllama-common.0.dylib"
        let compatibilityURL = fixture.runtimeDirectory.appendingPathComponent(
            compatibilityName)
        try FileManager.default.removeItem(at: compatibilityURL)
        try FileManager.default.createSymbolicLink(
            atPath: compatibilityURL.path,
            withDestinationPath: "libllama-common.0.0.9992.dylib")

        XCTAssertNoThrow(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory))
    }

    func testBundledCompatibilitySymlinkEscapingRuntimeFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let compatibilityName = "libllama-common.0.dylib"
        let compatibilityURL = fixture.runtimeDirectory.appendingPathComponent(
            compatibilityName)
        let outsideURL = fixture.root.appendingPathComponent("outside.dylib")
        try Data([0]).write(to: outsideURL)
        try FileManager.default.removeItem(at: compatibilityURL)
        try FileManager.default.createSymbolicLink(
            atPath: compatibilityURL.path,
            withDestinationPath: outsideURL.path)

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .bundledRuntimeIncomplete(compatibilityName))
        }
    }

    func testBrokenBundledCompatibilitySymlinkFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let compatibilityName = "libllama-common.0.dylib"
        let compatibilityURL = fixture.runtimeDirectory.appendingPathComponent(
            compatibilityName)
        try FileManager.default.removeItem(at: compatibilityURL)
        try FileManager.default.createSymbolicLink(
            atPath: compatibilityURL.path,
            withDestinationPath: "missing-libllama-common.dylib")

        XCTAssertThrowsError(try OSAtlasRuntimeInputResolver(
            manifest: fixture.manifest).resolve(
                receipt: fixture.receipt,
                runtimeDirectoryURL: fixture.runtimeDirectory,
                enclosingBundleURL: fixture.bundleDirectory)) { error in
            XCTAssertEqual(
                error as? OSAtlasRuntimeInstallationError,
                .bundledRuntimeIncomplete(compatibilityName))
        }
    }

    private struct Fixture {
        let root: URL
        let bundleDirectory: URL
        let runtimeDirectory: URL
        let modelDirectory: URL
        let manifest: ComputerUseArtifactManifest
        let receipt: ComputerUseInstallationReceipt
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OSAtlasRuntimeInstallationTests-\(UUID().uuidString)",
            isDirectory: true)
        let bundleDirectory = root.appendingPathComponent(
            "RemoteDesktopHost.app",
            isDirectory: true)
        let runtimeDirectory = bundleDirectory
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("llama-b9992", isDirectory: true)
        let modelDirectory = root.appendingPathComponent("Model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true)

        let artifacts: [ComputerUseArtifactManifest.DownloadableArtifact] = [
            .init(
                kind: .textModelShard,
                fileName: "os-atlas-pro-4b-q4_k_m-00001-of-00002.gguf",
                byteCount: 3,
                sha256: String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.invalid/one.gguf")!),
            .init(
                kind: .textModelShard,
                fileName: "os-atlas-pro-4b-q4_k_m-00002-of-00002.gguf",
                byteCount: 4,
                sha256: String(repeating: "b", count: 64),
                downloadURL: URL(string: "https://example.invalid/two.gguf")!),
            .init(
                kind: .visionProjector,
                fileName: "mmproj-os-atlas-pro-4b-f16.gguf",
                byteCount: 5,
                sha256: String(repeating: "c", count: 64),
                downloadURL: URL(string: "https://example.invalid/mmproj.gguf")!),
            .init(
                kind: .semanticRouterModel,
                fileName: "semantic-router-q4_k_m.gguf",
                byteCount: 6,
                sha256: String(repeating: "d", count: 64),
                downloadURL: URL(string:
                    "https://example.invalid/semantic-router-q4_k_m.gguf")!),
        ]
        for (artifact, byte) in zip(artifacts, [UInt8(1), 2, 3, 4]) {
            try Data(repeating: byte, count: Int(artifact.byteCount)).write(
                to: modelDirectory.appendingPathComponent(artifact.fileName))
        }
        for fileName in OSAtlasRuntimeInputResolver.requiredBundledRuntimeFiles {
            try Data([0]).write(to:
                runtimeDirectory.appendingPathComponent(fileName))
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeDirectory
                .appendingPathComponent("llama-server").path)

        let manifest = ComputerUseArtifactManifest(
            installationVersion: "os-atlas-runtime-test-v1",
            modelVariant: .pro4B,
            modelRepository: "OS-Copilot/OS-Atlas-Pro-4B",
            modelRevision: "test",
            modelArtifacts: artifacts,
            minimumMemoryBytes: 0)
        let receipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: .pro4B,
            modelDirectory: modelDirectory.path,
            installedAt: Date(timeIntervalSince1970: 0))
        return Fixture(
            root: root,
            bundleDirectory: bundleDirectory,
            runtimeDirectory: runtimeDirectory,
            modelDirectory: modelDirectory,
            manifest: manifest,
            receipt: receipt)
    }

    private func manifest(
        from source: ComputerUseArtifactManifest,
        artifacts: [ComputerUseArtifactManifest.DownloadableArtifact]
    ) -> ComputerUseArtifactManifest {
        ComputerUseArtifactManifest(
            installationVersion: source.installationVersion,
            modelVariant: source.modelVariant,
            modelRepository: source.modelRepository,
            modelRevision: source.modelRevision,
            modelArtifacts: artifacts,
            minimumMemoryBytes: source.minimumMemoryBytes)
    }
}

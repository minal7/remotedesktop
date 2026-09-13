import Foundation
import XCTest
@testable import RemoteDesktopHost

final class OSAtlasRuntimeInstallationTests: XCTestCase {
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
        let fixture = try makeFixture()
        for artifact in fixture.manifest.modelArtifacts {
            try FileManager.default.removeItem(at: fixture.modelDirectory.appendingPathComponent(artifact.fileName))
        }
        let artifacts = ComputerUseArtifactManifest.fara15.modelArtifacts.map {
            ComputerUseArtifactManifest.DownloadableArtifact(kind: $0.kind, fileName: $0.fileName,
                byteCount: 3, sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                downloadURL: $0.downloadURL)
        }
        for artifact in artifacts { try Data([1, 2, 3]).write(to: fixture.modelDirectory.appendingPathComponent(artifact.fileName)) }
        let manifest = ComputerUseArtifactManifest(installationVersion: "fara-fixture", modelVariant: .fara15_4B,
            modelRepository: "test/fara", modelRevision: "test-revision", modelArtifacts: artifacts, minimumMemoryBytes: 0)
        return Fixture(root: fixture.root, bundleDirectory: fixture.bundleDirectory,
            runtimeDirectory: fixture.runtimeDirectory, modelDirectory: fixture.modelDirectory, manifest: manifest,
            receipt: .init(installationVersion: manifest.installationVersion, modelVariant: .fara15_4B,
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

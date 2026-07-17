import Foundation
import XCTest
@testable import RemoteDesktopHost

final class OSAtlasRuntimeInstallationTests: XCTestCase {
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

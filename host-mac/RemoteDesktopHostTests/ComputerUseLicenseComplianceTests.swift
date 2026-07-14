import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseLicenseComplianceTests: XCTestCase {
    func testBundledOSAtlasAndLlamaCPPDocumentsMatchPinnedManifest() throws {
        XCTAssertEqual(
            ComputerUseArtifactManifest.osAtlasLicenseURL.absoluteString,
            "https://github.com/OS-Copilot/OS-Atlas/blob/bad08407ab54b5bf6c17a69fe1ced476b9494926/LICENSE")
        XCTAssertEqual(ComputerUseArtifactManifest.llamaCPPTag, "b9992")
        XCTAssertEqual(
            ComputerUseArtifactManifest.llamaCPPLicenseURL.absoluteString,
            "https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/LICENSE")

        for artifact in ComputerUseArtifactManifest.modelLegalArtifacts {
            let url = try bundledURL(for: artifact)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Int64(data.count), artifact.byteCount, artifact.fileName)
            XCTAssertEqual(Self.sha256(data), artifact.sha256, artifact.fileName)
        }

        let osAtlasLicense = try String(
            contentsOf: bundledURL(for: ComputerUseArtifactManifest.osAtlasLicense),
            encoding: .utf8)
        XCTAssertTrue(osAtlasLicense.contains("Apache License"))
        XCTAssertTrue(osAtlasLicense.contains("Version 2.0, January 2004"))

        let llamaLicense = try String(
            contentsOf: bundledURL(for: ComputerUseArtifactManifest.llamaCPPLicense),
            encoding: .utf8)
        XCTAssertTrue(llamaLicense.hasPrefix("MIT License\n"))
        XCTAssertTrue(llamaLicense.contains("Copyright (c) 2023-2026 The ggml authors"))

        let notice = try String(
            contentsOf: bundledURL(for: ComputerUseArtifactManifest.modelNotice),
            encoding: .utf8)
        XCTAssertTrue(notice.contains(ComputerUseArtifactManifest.osAtlasPro4BRevision))
        XCTAssertTrue(notice.contains(ComputerUseArtifactManifest.llamaCPPRevision))
        XCTAssertTrue(notice.contains("split Q4_K_M GGUF"))
        XCTAssertTrue(notice.contains("F16 GGUF vision projector"))
        XCTAssertTrue(notice.contains("does not add executable code"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("Qwen"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("LoRA"))
    }

    func testBundledMacControlMCPLicenseAndNoticeArePresent() throws {
        let licenseText = try String(
            contentsOf: bundledURL(fileName: "MAC-CONTROL-MCP-LICENSE.txt"),
            encoding: .utf8)
        XCTAssertTrue(licenseText.hasPrefix("MIT License\n"))
        XCTAssertTrue(licenseText.contains("Copyright (c) 2026 Adil El-Ouariachi"))

        let noticeText = try String(
            contentsOf: bundledURL(for: ComputerUseArtifactManifest.modelNotice),
            encoding: .utf8)
        XCTAssertTrue(noticeText.contains(
            "mac-control-mcp is licensed under the MIT License"))
    }

    func testExistingReceiptRepairsMissingAndTamperedLegalDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = ComputerUseInstaller(
            manifest: fixture.manifest,
            rootDirectory: fixture.root,
            legalResourceDirectory: fixture.legalSource)

        let repairedReceipt = await installer.currentInstallation()
        XCTAssertEqual(repairedReceipt, fixture.receipt)
        try assertInstalledDocumentsMatchSource(fixture)

        let installedNotice = fixture.modelDirectory.appendingPathComponent(
            ComputerUseArtifactManifest.modelNotice.fileName)
        try Data(
            repeating: 0x78,
            count: Int(ComputerUseArtifactManifest.modelNotice.byteCount))
            .write(to: installedNotice, options: .atomic)

        let repairedTamperedReceipt = await installer.currentInstallation()
        XCTAssertEqual(repairedTamperedReceipt, fixture.receipt)
        try assertInstalledDocumentsMatchSource(fixture)
    }

    func testExistingReceiptFailsClosedWhenBundledNoticeIsInvalid() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let notice = fixture.legalSource.appendingPathComponent(
            ComputerUseArtifactManifest.modelNotice.fileName)
        try Data(
            repeating: 0x78,
            count: Int(ComputerUseArtifactManifest.modelNotice.byteCount))
            .write(to: notice, options: .atomic)

        let installer = ComputerUseInstaller(
            manifest: fixture.manifest,
            rootDirectory: fixture.root,
            legalResourceDirectory: fixture.legalSource)
        let invalidReceipt = await installer.currentInstallation()
        XCTAssertNil(invalidReceipt)
    }

    func testModelPackageHasNoPrivateAdapterOrExecutableDownloadPath() throws {
        let hostDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestSource = try String(
            contentsOf: hostDirectory.appendingPathComponent(
                "RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift"),
            encoding: .utf8)
        let installerSource = try String(
            contentsOf: hostDirectory.appendingPathComponent(
                "RemoteDesktopHost/ComputerUse/ComputerUseInstaller.swift"),
            encoding: .utf8)

        for source in [manifestSource, installerSource] {
            XCTAssertFalse(source.contains("minal7/computer-use-lora"))
            XCTAssertFalse(source.contains("adapter_model.safetensors"))
            XCTAssertFalse(source.contains("Qwen2.5-VL"))
        }
        XCTAssertEqual(ComputerUseArtifactManifest.current.modelVariant, .pro4B)
        XCTAssertTrue(ComputerUseArtifactManifest.current.modelArtifacts.allSatisfy {
            $0.fileName.hasSuffix(".gguf") && $0.downloadURL.scheme == "https"
        })
    }

    private struct Fixture {
        let root: URL
        let legalSource: URL
        let modelDirectory: URL
        let manifest: ComputerUseArtifactManifest
        let receipt: ComputerUseInstallationReceipt
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComputerUseLicenseTests-\(UUID().uuidString)",
            isDirectory: true)
        let legalSource = root.appendingPathComponent("BundledLegal", isDirectory: true)
        let model = root.appendingPathComponent(
            "Models/license-test-v1",
            isDirectory: true)
        for directory in [legalSource, model] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        }

        for artifact in ComputerUseArtifactManifest.modelLegalArtifacts {
            try Data(contentsOf: bundledURL(for: artifact)).write(
                to: legalSource.appendingPathComponent(artifact.fileName),
                options: .atomic)
        }
        try Data([1, 2, 3]).write(to: model.appendingPathComponent("model.gguf"))

        let manifest = ComputerUseArtifactManifest(
            installationVersion: "license-test-v1",
            modelVariant: .pro4B,
            modelRepository: "test/model",
            modelRevision: "test-revision",
            modelArtifacts: [.init(
                kind: .textModelShard,
                fileName: "model.gguf",
                byteCount: 3,
                sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                downloadURL: URL(string: "https://example.invalid/model.gguf")!)],
            minimumMemoryBytes: 0)
        let receipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: manifest.modelVariant,
            modelDirectory: model.path,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONEncoder().encode(receipt).write(
            to: root.appendingPathComponent("active-installation.json"),
            options: .atomic)

        return Fixture(
            root: root,
            legalSource: legalSource,
            modelDirectory: model,
            manifest: manifest,
            receipt: receipt)
    }

    private func assertInstalledDocumentsMatchSource(_ fixture: Fixture) throws {
        for artifact in ComputerUseArtifactManifest.modelLegalArtifacts {
            let expected = try Data(contentsOf:
                fixture.legalSource.appendingPathComponent(artifact.fileName))
            XCTAssertEqual(
                try Data(contentsOf:
                    fixture.modelDirectory.appendingPathComponent(artifact.fileName)),
                expected,
                artifact.fileName)
        }
    }

    private func bundledURL(
        for artifact: ComputerUseArtifactManifest.BundledArtifact
    ) throws -> URL {
        let bundles = [
            Bundle.main,
            Bundle(for: ComputerUseLicenseComplianceTests.self),
        ] + Bundle.allBundles + Bundle.allFrameworks
        return try XCTUnwrap(
            ComputerUseArtifactManifest.bundledLegalDocumentURL(
                artifact,
                bundles: bundles),
            "Missing bundled resource \(artifact.fileName)")
    }

    private func bundledURL(fileName: String) throws -> URL {
        let name = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        let bundles = [
            Bundle.main,
            Bundle(for: ComputerUseLicenseComplianceTests.self),
        ] + Bundle.allBundles + Bundle.allFrameworks
        return try XCTUnwrap(
            bundles.lazy.compactMap {
                $0.url(
                    forResource: name,
                    withExtension: fileExtension.isEmpty ? nil : fileExtension)
            }.first,
            "Missing bundled resource \(fileName)")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseLicenseComplianceTests: XCTestCase {
    func testVerifiedCompletedPackageCommitsWithMetadataSpaceAndNoDownload() async throws {
        for staged in [false, true] {
            let fixture = try makeFixture(modelVariant: .nativeText4B)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("active-installation.json"))
            if staged {
                let staging = fixture.root.appendingPathComponent("Models/.license-test-v1-staging", isDirectory: true)
                try FileManager.default.moveItem(at: fixture.modelDirectory, to: staging)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RejectPackageDownload.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            RejectPackageDownload.reset()
            let installer = ComputerUseInstaller(manifest: fixture.manifest, rootDirectory: fixture.root,
                legalResourceDirectory: fixture.legalSource, downloadSession: session, legacyManifest: nil,
                operations: .init(createHardLink: { _, _ in }, availableCapacity: { _ in 128 * 1_024 * 1_024 }))
            let before = await installer.currentInstallation()
            XCTAssertNil(before, "Cached model bytes alone are not an installation receipt")
            let receipt = try await installer.install { _ in }
            XCTAssertEqual(receipt.modelDirectory, fixture.modelDirectory.path)
            let after = await installer.currentInstallation()
            XCTAssertEqual(after, receipt)
            try assertInstalledDocumentsMatchSource(fixture)
            XCTAssertEqual(RejectPackageDownload.requestCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
                .appendingPathComponent(ComputerUseInstaller.interruptedInstallationMarkerName).path))
        }
    }

    func testOnlyChecksumVerifiedCompletePackageCanUseMetadataSpaceBudget() async throws {
        for bytes in [Data(), Data([1]), Data([3, 2, 1]), Data([1, 2, 3])] {
            let fixture = try makeFixture(modelVariant: .nativeText4B)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("active-installation.json"))
            let model = fixture.modelDirectory.appendingPathComponent("model.gguf")
            if bytes.isEmpty { try FileManager.default.removeItem(at: model) }
            else { try bytes.write(to: model) }
            let isComplete = bytes == Data([1, 2, 3])
            let available: Int64 = isComplete ? ComputerUseInstaller.cachedPackageHeadroomBytes - 1 : 128 * 1_024 * 1_024
            let installer = ComputerUseInstaller(manifest: fixture.manifest, rootDirectory: fixture.root,
                legalResourceDirectory: fixture.legalSource, legacyManifest: nil,
                operations: .init(createHardLink: { _, _ in }, availableCapacity: { _ in available }))
            do { try await installer.preflight(); XCTFail("Insufficient space must reject before install") }
            catch let error as ComputerUseInstaller.InstallError {
                XCTAssertEqual(error, .insufficientDisk(required: isComplete
                    ? ComputerUseInstaller.cachedPackageHeadroomBytes
                    : ComputerUseInstaller.requiredDiskBytes(forModelBytes: 3), available: available))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active-installation.json").path))
        }
    }

    func testNativeTextPackageInstallsItsOwnVerifiedLegalDocumentsIndependently() async throws {
        let fixture = try makeFixture(modelVariant: .nativeText4B)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = ComputerUseInstaller(manifest: fixture.manifest, rootDirectory: fixture.root,
            legalResourceDirectory: fixture.legalSource, legacyManifest: nil)
        let receipt = try await installer.install { _ in }
        XCTAssertEqual(receipt.modelVariant, .nativeText4B)
        try assertInstalledDocumentsMatchSource(fixture)
        for artifact in [ComputerUseArtifactManifest.osAtlasLicense, ComputerUseArtifactManifest.graniteLicense,
                         ComputerUseArtifactManifest.modelNotice] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.modelDirectory.appendingPathComponent(artifact.fileName).path))
        }
        XCTAssertNotEqual(ComputerUseInstaller.nativeTextRootDirectory, HostComputerUseManager.modelDirectoryURL)
        for artifact in ComputerUseArtifactManifest.nativeTextV2.legalArtifacts {
            let bytes = try Data(contentsOf: bundledURL(for: artifact))
            XCTAssertEqual(Int64(bytes.count), artifact.byteCount)
            XCTAssertEqual(Self.sha256(bytes), artifact.sha256)
        }
        let notice = try String(contentsOf: bundledURL(for: ComputerUseArtifactManifest.qwen35Notice), encoding: .utf8)
        XCTAssertTrue(notice.contains(ComputerUseArtifactManifest.nativeTextV2.modelRevision))
        XCTAssertTrue(notice.contains(ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256))
        XCTAssertEqual(ComputerUseArtifactManifest.current, .fara15)
    }

    func testBundledModelAndLlamaCPPDocumentsMatchPinnedManifest() throws {
        XCTAssertEqual(
            ComputerUseArtifactManifest.osAtlasLicenseURL.absoluteString,
            "https://github.com/OS-Copilot/OS-Atlas/blob/bad08407ab54b5bf6c17a69fe1ced476b9494926/LICENSE")
        XCTAssertEqual(
            ComputerUseArtifactManifest.granite4OneBRevision,
            "6a7381ba1f54d684ff508d991aeb7dc580157103")
        XCTAssertEqual(
            ComputerUseArtifactManifest.graniteLicenseURL.absoluteString,
            "https://github.com/ibm-granite/granite-4.0-nano-language-models/blob/1c66d6a87aaa251ef88a3154393d3dddba497bfa/LICENSE")
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

        let graniteLicense = try String(
            contentsOf: bundledURL(for: ComputerUseArtifactManifest.graniteLicense),
            encoding: .utf8)
        XCTAssertTrue(graniteLicense.contains("Apache License"))
        XCTAssertTrue(graniteLicense.contains("Version 2.0, January 2004"))

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

    func testUserRequestedInstallRepairsMissingAndTamperedLegalDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = ComputerUseInstaller(
            manifest: fixture.manifest,
            rootDirectory: fixture.root,
            legalResourceDirectory: fixture.legalSource)

        let passiveReceipt = await installer.currentInstallation()
        XCTAssertEqual(passiveReceipt, fixture.receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.modelDirectory.appendingPathComponent(
                ComputerUseArtifactManifest.modelNotice.fileName).path))

        let repairedReceipt = try await installer.install { _ in }
        XCTAssertEqual(repairedReceipt, fixture.receipt)
        try assertInstalledDocumentsMatchSource(fixture)

        let installedNotice = fixture.modelDirectory.appendingPathComponent(
            ComputerUseArtifactManifest.modelNotice.fileName)
        try Data(
            repeating: 0x78,
            count: Int(ComputerUseArtifactManifest.modelNotice.byteCount))
            .write(to: installedNotice, options: .atomic)

        let repairedTamperedReceipt = try await installer.install { _ in }
        XCTAssertEqual(repairedTamperedReceipt, fixture.receipt)
        try assertInstalledDocumentsMatchSource(fixture)
    }

    func testUserRequestedRepairFailsClosedWhenBundledNoticeIsInvalid() async throws {
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
        let passiveReceipt = await installer.currentInstallation()
        XCTAssertEqual(passiveReceipt, fixture.receipt)
        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected invalid bundled notice")
        } catch let error as ComputerUseInstaller.InstallError {
            XCTAssertEqual(
                error,
                .checksumMismatch(ComputerUseArtifactManifest.modelNotice.fileName))
        }
    }

    func testModelPackagesContainOnlyPinnedGGUFDownloads() throws {
        for manifest in [ComputerUseArtifactManifest.current, .nativeTextV2] {
            XCTAssertFalse(manifest.modelArtifacts.isEmpty)
            XCTAssertTrue(manifest.modelArtifacts.allSatisfy {
                $0.fileName.hasSuffix(".gguf") && $0.downloadURL.scheme == "https"
                    && $0.byteCount > 0 && $0.sha256.count == 64
            })
        }
        XCTAssertEqual(ComputerUseArtifactManifest.current.modelVariant, .fara15_4B)
        XCTAssertEqual(ComputerUseArtifactManifest.nativeTextV2.modelArtifacts.map(\.kind), [.nativeTextPlannerModel])
    }

    private struct Fixture {
        let root: URL
        let legalSource: URL
        let modelDirectory: URL
        let manifest: ComputerUseArtifactManifest
        let receipt: ComputerUseInstallationReceipt
    }

    private func makeFixture(modelVariant: ComputerUseArtifactManifest.ModelVariant = .pro4B) throws -> Fixture {
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

        let documents = modelVariant == .nativeText4B
            ? ComputerUseArtifactManifest.nativeTextV2.legalArtifacts
            : ComputerUseArtifactManifest.modelLegalArtifacts
        for artifact in documents {
            try Data(contentsOf: bundledURL(for: artifact)).write(
                to: legalSource.appendingPathComponent(artifact.fileName),
                options: .atomic)
        }
        try Data([1, 2, 3]).write(to: model.appendingPathComponent("model.gguf"))

        let manifest = ComputerUseArtifactManifest(
            installationVersion: "license-test-v1",
            modelVariant: modelVariant,
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
        for artifact in fixture.manifest.legalArtifacts {
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

private final class RejectPackageDownload: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}

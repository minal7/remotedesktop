import CryptoKit
import XCTest
@testable import RemoteDesktopHost

final class MacControlMCPInstallerTests: XCTestCase {
    func test_manifestPinsPublishedNativeUniversalRelease() {
        let manifest = MacControlMCPArtifactManifest.current

        XCTAssertEqual(manifest.version, "0.8.2")
        XCTAssertEqual(manifest.archiveFileName, "MacControlMCP-v0.8.2-macos-universal.tar.gz")
        XCTAssertEqual(manifest.archiveByteCount, 2_581_884)
        XCTAssertEqual(
            manifest.archiveSHA256,
            "1681fd2ccbf53d6fceebdaed0d5d49513637fe9929ff6eb9d1e1984ad6cb472e")
        XCTAssertEqual(
            manifest.executableSHA256,
            "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302")
        XCTAssertEqual(
            manifest.downloadURL.absoluteString,
            "https://github.com/AdelElo13/mac-control-mcp/releases/download/v0.8.2/MacControlMCP-v0.8.2-macos-universal.tar.gz")
        XCTAssertEqual(manifest.bundleIdentifier, "dev.macmcp.server")
        XCTAssertEqual(manifest.teamIdentifier, "A3W973JZ49")
        XCTAssertEqual(
            manifest.signingIdentity,
            "Developer ID Application: Adil El-Ouariachi (A3W973JZ49)")
    }

    func test_archiveListingMustStayInsideExpectedSignedApp() throws {
        let valid = """
        MacControlMCP.app/
        MacControlMCP.app/Contents/
        MacControlMCP.app/Contents/Info.plist
        MacControlMCP.app/Contents/MacOS/MacControlMCP
        MacControlMCP.app/Contents/_CodeSignature/CodeResources
        """
        XCTAssertNoThrow(try SystemMacControlMCPArchiveExtractor.validateArchiveEntries(
            valid,
            manifest: .current))

        let escaping = valid + "\n../outside"
        XCTAssertThrowsError(try SystemMacControlMCPArchiveExtractor.validateArchiveEntries(
            escaping,
            manifest: .current))

        let extraTopLevel = valid + "\nrun-me.sh"
        XCTAssertThrowsError(try SystemMacControlMCPArchiveExtractor.validateArchiveEntries(
            extraTopLevel,
            manifest: .current))
    }

    func test_trustValidatorPinsDeveloperIDHardenedRuntimeUniversalAndNotarization() async throws {
        let fixture = try makeFakeApp(manifest: .current)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = TrustCommandRunner(identityIsValid: true)
        let validator = MacControlMCPTrustValidator(commandRunner: runner)

        let evidence = try await validator.validate(
            appURL: fixture.app,
            manifest: .current)

        XCTAssertEqual(evidence.bundleIdentifier, "dev.macmcp.server")
        XCTAssertEqual(evidence.teamIdentifier, "A3W973JZ49")
        XCTAssertEqual(
            evidence.signingIdentity,
            "Developer ID Application: Adil El-Ouariachi (A3W973JZ49)")
        XCTAssertTrue(evidence.hasHardenedRuntime)
        XCTAssertTrue(evidence.isUniversalBinary)
        XCTAssertTrue(evidence.gatekeeperAcceptedNotarization)
        XCTAssertTrue(evidence.stapledTicketValidated)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(
            calls.map(\.executableName),
            ["codesign", "codesign", "lipo", "spctl", "xcrun"])
        XCTAssertFalse(calls.contains(where: { $0.executablePath == fixture.binary.path }))
    }

    func test_trustValidatorRejectsDifferentDeveloperIdentity() async throws {
        let fixture = try makeFakeApp(manifest: .current)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let validator = MacControlMCPTrustValidator(
            commandRunner: TrustCommandRunner(identityIsValid: false))

        do {
            _ = try await validator.validate(appURL: fixture.app, manifest: .current)
            XCTFail("Expected the unpinned signing identity to be rejected")
        } catch let error as MacControlMCPTrustValidator.ValidationError {
            XCTAssertEqual(error, .unexpectedSigningIdentity)
        }
    }

    func test_initializationAndStatusDoNotCreateFilesOrStartInstallation() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacControlExplicit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = MacControlMCPInstaller(
            rootDirectory: root,
            archiveExtractor: TestArchiveExtractor(),
            trustValidator: AcceptingTrustValidator())

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let status = await installer.durableStatus()
        XCTAssertEqual(status, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func test_installResumesDurableBytesWritesIdempotentReceiptAndNeverLaunchesBinary() async throws {
        let payload = Data((0 ..< 43).map(UInt8.init))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacControlInstall-\(UUID().uuidString)", isDirectory: true)
        let manifest = testManifest(payload: payload)
        let archive = root
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(manifest.archiveFileName)
        defer {
            MCPRangeURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try payload.prefix(7).write(to: archive)

        MCPRangeURLProtocol.configure(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPRangeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let trust = AcceptingTrustValidator()
        let installer = MacControlMCPInstaller(
            manifest: manifest,
            rootDirectory: root,
            downloadSession: session,
            downloadChunkByteCount: 5,
            archiveExtractor: TestArchiveExtractor(),
            trustValidator: trust)
        var updates: [MacControlMCPInstaller.Update] = []

        let firstReceipt = try await installer.install { updates.append($0) }

        XCTAssertEqual(MCPRangeURLProtocol.requestedRanges().first, "bytes=7-11")
        XCTAssertEqual(firstReceipt.packageVersion, manifest.version)
        XCTAssertEqual(firstReceipt.archiveSHA256, manifest.archiveSHA256)
        XCTAssertEqual(firstReceipt.executableSHA256, manifest.executableSHA256)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: firstReceipt.binaryPath))
        XCTAssertEqual(updates.first?.phase, .preparing)
        XCTAssertEqual(updates.last?.phase, .ready)
        let fractions = updates.map(\.fraction)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }

        let requestsAfterFirstInstall = MCPRangeURLProtocol.requestedRanges()
        var secondUpdates: [MacControlMCPInstaller.Update] = []
        let secondReceipt = try await installer.install { secondUpdates.append($0) }
        XCTAssertEqual(secondReceipt, firstReceipt)
        XCTAssertEqual(MCPRangeURLProtocol.requestedRanges(), requestsAfterFirstInstall)
        XCTAssertEqual(secondUpdates.map(\.phase), [.ready])
        let durableStatus = await installer.durableStatus()
        XCTAssertEqual(durableStatus, .ready(firstReceipt))

        let launch = try await installer.launchConfiguration()
        XCTAssertEqual(launch.executableURL.path, firstReceipt.binaryPath)
        XCTAssertTrue(launch.arguments.isEmpty)
        XCTAssertEqual(
            Set(launch.environmentOverrides.keys),
            Set(["MAC_CONTROL_MCP_HOME"]))
        XCTAssertFalse(launch.environmentOverrides.keys.contains(where: {
            $0.localizedCaseInsensitiveContains("api")
                || $0.localizedCaseInsensitiveContains("shell")
                || $0.localizedCaseInsensitiveContains("scrape")
        }))
        let validationCount = await trust.validationCount()
        XCTAssertGreaterThanOrEqual(validationCount, 3)

        try Data("tampered helper\n".utf8).write(
            to: URL(fileURLWithPath: firstReceipt.binaryPath))
        let tamperedStatus = await installer.durableStatus()
        XCTAssertEqual(tamperedStatus, .repairRequired)
    }

    func test_downloadProgressReflectsPersistedByteFraction() {
        let update = MacControlMCPInstaller.downloadUpdate(
            downloadedByteCount: 25,
            totalByteCount: 100)

        XCTAssertEqual(update.phase, .downloading)
        XCTAssertEqual(update.fraction, 0.2125, accuracy: 0.000_001)
        XCTAssertEqual(update.downloadedByteCount, 25)
        XCTAssertEqual(update.totalByteCount, 100)
        XCTAssertTrue(update.detail.contains(" of "))
    }

    private func testManifest(payload: Data) -> MacControlMCPArtifactManifest {
        MacControlMCPArtifactManifest(
            version: "test-0.8.2",
            archiveFileName: "fixture.tar.gz",
            archiveByteCount: Int64(payload.count),
            archiveSHA256: SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }
                .joined(),
            downloadURL: URL(string: "https://mcp.test/fixture.tar.gz")!,
            appBundleName: "MacControlMCP.app",
            executableName: "MacControlMCP",
            executableSHA256: SHA256.hash(data: TestArchiveExtractor.binaryPayload)
                .map { String(format: "%02x", $0) }
                .joined(),
            bundleIdentifier: "dev.macmcp.server",
            teamIdentifier: "A3W973JZ49",
            signingIdentity: "Developer ID Application: Adil El-Ouariachi (A3W973JZ49)")
    }

    private func makeFakeApp(
        manifest: MacControlMCPArtifactManifest
    ) throws -> (root: URL, app: URL, binary: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacControlTrust-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(manifest.appBundleName, isDirectory: true)
        return try TestArchiveExtractor.makeApp(at: app, manifest: manifest)
            .mapRoot(root)
    }
}

private struct TestAppFixture {
    let app: URL
    let binary: URL

    func mapRoot(_ root: URL) -> (root: URL, app: URL, binary: URL) {
        (root, app, binary)
    }
}

private struct TestArchiveExtractor: MacControlMCPArchiveExtracting {
    static let binaryPayload = Data("test fixture; never execute\n".utf8)

    func extract(
        archiveURL: URL,
        destinationDirectory: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> URL {
        let app = destinationDirectory
            .appendingPathComponent(manifest.appBundleName, isDirectory: true)
        return try Self.makeApp(at: app, manifest: manifest).app
    }

    static func makeApp(
        at app: URL,
        manifest: MacControlMCPArtifactManifest
    ) throws -> TestAppFixture {
        let fileManager = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let signature = app.appendingPathComponent(
            "Contents/_CodeSignature",
            isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: signature, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": manifest.bundleIdentifier,
            "CFBundleShortVersionString": manifest.version,
            "CFBundleExecutable": manifest.executableName,
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let binary = macOS.appendingPathComponent(manifest.executableName)
        try binaryPayload.write(to: binary)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path)
        try Data("signature fixture\n".utf8).write(
            to: signature.appendingPathComponent("CodeResources"))
        return TestAppFixture(app: app, binary: binary)
    }
}

private actor AcceptingTrustValidator: MacControlMCPTrustValidating {
    private var count = 0

    func validate(
        appURL: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> MacControlMCPTrustEvidence {
        count += 1
        return MacControlMCPTrustEvidence(
            bundleIdentifier: manifest.bundleIdentifier,
            teamIdentifier: manifest.teamIdentifier,
            signingIdentity: manifest.signingIdentity,
            hasHardenedRuntime: true,
            isUniversalBinary: true,
            gatekeeperAcceptedNotarization: true,
            stapledTicketValidated: true)
    }

    func validationCount() -> Int { count }
}

private actor TrustCommandRunner: MacControlMCPCommandRunning {
    struct Call: Equatable, Sendable {
        let executablePath: String
        let arguments: [String]

        var executableName: String {
            URL(fileURLWithPath: executablePath).lastPathComponent
        }
    }

    private let identityIsValid: Bool
    private var calls: [Call] = []

    init(identityIsValid: Bool) {
        self.identityIsValid = identityIsValid
    }

    func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> MacControlMCPCommandResult {
        calls.append(Call(executablePath: executableURL.path, arguments: arguments))
        switch (executableURL.lastPathComponent, arguments.first) {
        case ("codesign", "--verify"):
            return .init(terminationStatus: 0, standardOutput: "", standardError: "valid on disk")
        case ("codesign", "-dvvv"):
            let identity = identityIsValid
                ? "Developer ID Application: Adil El-Ouariachi (A3W973JZ49)"
                : "Developer ID Application: Someone Else (ZZZZZZZZZZ)"
            return .init(
                terminationStatus: 0,
                standardOutput: "",
                standardError: """
                Identifier=dev.macmcp.server
                CodeDirectory v=20500 flags=0x10000(runtime)
                Authority=\(identity)
                TeamIdentifier=A3W973JZ49
                """)
        case ("lipo", "-archs"):
            return .init(terminationStatus: 0, standardOutput: "x86_64 arm64\n", standardError: "")
        case ("spctl", "--assess"):
            return .init(
                terminationStatus: 0,
                standardOutput: "",
                standardError: "accepted\nsource=Notarized Developer ID\n")
        case ("xcrun", "stapler"):
            return .init(
                terminationStatus: 0,
                standardOutput: "The validate action worked!\n",
                standardError: "")
        default:
            return .init(terminationStatus: 127, standardOutput: "", standardError: "unexpected")
        }
    }

    func recordedCalls() -> [Call] { calls }
}

private final class MCPRangeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var ranges: [String] = []

    static func configure(payload: Data) {
        lock.withLock {
            self.payload = payload
            ranges = []
        }
    }

    static func reset() {
        lock.withLock {
            payload = Data()
            ranges = []
        }
    }

    static func requestedRanges() -> [String] {
        lock.withLock { ranges }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let range = request.value(forHTTPHeaderField: "Range"),
              let byteRange = Self.parse(range) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data = Self.lock.withLock { () -> Data in
            Self.ranges.append(range)
            return Self.payload
        }
        guard byteRange.lowerBound >= 0,
              byteRange.upperBound < data.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = data.subdata(in: byteRange.lowerBound ..< (byteRange.upperBound + 1))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(data.count)",
                "Content-Length": "\(body.count)",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ value: String) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let pieces = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard pieces.count == 2,
              let start = Int(pieces[0]),
              let end = Int(pieces[1]) else { return nil }
        return start ... end
    }
}

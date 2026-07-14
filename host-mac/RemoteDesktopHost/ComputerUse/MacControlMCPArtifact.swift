import Foundation

struct MacControlMCPArtifactManifest: Equatable, Sendable {
    let version: String
    let archiveFileName: String
    let archiveByteCount: Int64
    let archiveSHA256: String
    let downloadURL: URL
    let appBundleName: String
    let executableName: String
    let executableSHA256: String
    let bundleIdentifier: String
    let teamIdentifier: String
    let signingIdentity: String

    static let current = MacControlMCPArtifactManifest(
        version: "0.8.2",
        archiveFileName: "MacControlMCP-v0.8.2-macos-universal.tar.gz",
        archiveByteCount: 2_581_884,
        archiveSHA256: "1681fd2ccbf53d6fceebdaed0d5d49513637fe9929ff6eb9d1e1984ad6cb472e",
        downloadURL: URL(
            string: "https://github.com/AdelElo13/mac-control-mcp/releases/download/v0.8.2/MacControlMCP-v0.8.2-macos-universal.tar.gz")!,
        appBundleName: "MacControlMCP.app",
        executableName: "MacControlMCP",
        executableSHA256: "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302",
        bundleIdentifier: "dev.macmcp.server",
        teamIdentifier: "A3W973JZ49",
        signingIdentity: "Developer ID Application: Adil El-Ouariachi (A3W973JZ49)")
}

struct MacControlMCPInstallationReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let packageVersion: String
    let archiveSHA256: String
    let appBundlePath: String
    let binaryPath: String
    let executableSHA256: String?
    let bundleIdentifier: String
    let teamIdentifier: String
    let signingIdentity: String
    let installedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        packageVersion: String,
        archiveSHA256: String,
        appBundlePath: String,
        binaryPath: String,
        executableSHA256: String? = nil,
        bundleIdentifier: String,
        teamIdentifier: String,
        signingIdentity: String,
        installedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.packageVersion = packageVersion
        self.archiveSHA256 = archiveSHA256
        self.appBundlePath = appBundlePath
        self.binaryPath = binaryPath
        self.executableSHA256 = executableSHA256
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingIdentity = signingIdentity
        self.installedAt = installedAt
    }
}

/// A launch description only. Constructing it never starts the MCP server.
/// The eventual host integration can use the same verified receipt while
/// keeping all MCP state under the host's Application Support directory.
struct MacControlMCPLaunchConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environmentOverrides: [String: String]

    init(receipt: MacControlMCPInstallationReceipt, stateDirectory: URL) {
        executableURL = URL(fileURLWithPath: receipt.binaryPath)
        arguments = []
        environmentOverrides = [
            "MAC_CONTROL_MCP_HOME": stateDirectory.standardizedFileURL.path,
        ]
    }
}

struct MacControlMCPCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        standardOutput + "\n" + standardError
    }
}

protocol MacControlMCPCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> MacControlMCPCommandResult
}

struct FoundationMacControlMCPCommandRunner: MacControlMCPCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> MacControlMCPCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            process.waitUntilExit()
            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            return MacControlMCPCommandResult(
                terminationStatus: process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self))
        }.value
    }
}

struct MacControlMCPTrustEvidence: Equatable, Sendable {
    let bundleIdentifier: String
    let teamIdentifier: String
    let signingIdentity: String
    let hasHardenedRuntime: Bool
    let isUniversalBinary: Bool
    let gatekeeperAcceptedNotarization: Bool
    let stapledTicketValidated: Bool
}

protocol MacControlMCPTrustValidating: Sendable {
    func validate(
        appURL: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> MacControlMCPTrustEvidence
}

struct MacControlMCPTrustValidator: MacControlMCPTrustValidating, @unchecked Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidBundle
        case invalidExecutable
        case invalidCodeSignature
        case unexpectedSigningIdentity
        case missingHardenedRuntime
        case notUniversal
        case gatekeeperRejected
        case notarizationTicketInvalid

        var errorDescription: String? {
            switch self {
            case .invalidBundle:
                return "The downloaded MCP app has invalid bundle metadata."
            case .invalidExecutable:
                return "The downloaded MCP app does not contain the expected executable."
            case .invalidCodeSignature:
                return "The downloaded MCP app's code signature is invalid."
            case .unexpectedSigningIdentity:
                return "The downloaded MCP app was not signed by the pinned developer identity."
            case .missingHardenedRuntime:
                return "The downloaded MCP app is not protected by the hardened runtime."
            case .notUniversal:
                return "The downloaded MCP app is not the pinned universal macOS build."
            case .gatekeeperRejected:
                return "macOS Gatekeeper did not accept the downloaded MCP app as notarized."
            case .notarizationTicketInvalid:
                return "The downloaded MCP app's stapled notarization ticket is invalid."
            }
        }
    }

    private let commandRunner: any MacControlMCPCommandRunning
    private let fileManager: FileManager

    init(
        commandRunner: any MacControlMCPCommandRunning = FoundationMacControlMCPCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func validate(
        appURL: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> MacControlMCPTrustEvidence {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              plist["CFBundleShortVersionString"] as? String == manifest.version,
              plist["CFBundleExecutable"] as? String == manifest.executableName else {
            throw ValidationError.invalidBundle
        }

        let binaryURL = appURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(manifest.executableName)
        guard let values = try? binaryURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: binaryURL.path) else {
            throw ValidationError.invalidExecutable
        }

        let codeVerification = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=4", appURL.path])
        guard codeVerification.terminationStatus == 0 else {
            throw ValidationError.invalidCodeSignature
        }

        let codeDetails = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dvvv", appURL.path])
        let details = codeDetails.combinedOutput
        guard codeDetails.terminationStatus == 0,
              Self.hasLine("Identifier=\(manifest.bundleIdentifier)", in: details),
              Self.hasLine("TeamIdentifier=\(manifest.teamIdentifier)", in: details),
              Self.hasLine("Authority=\(manifest.signingIdentity)", in: details) else {
            throw ValidationError.unexpectedSigningIdentity
        }
        guard details.contains("flags=0x10000(runtime)") else {
            throw ValidationError.missingHardenedRuntime
        }

        let architectures = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", binaryURL.path])
        let architectureSet = Set(
            architectures.standardOutput
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init))
        guard architectures.terminationStatus == 0,
              architectureSet.contains("arm64"),
              architectureSet.contains("x86_64") else {
            throw ValidationError.notUniversal
        }

        let gatekeeper = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=4", appURL.path])
        let gatekeeperOutput = gatekeeper.combinedOutput.lowercased()
        guard gatekeeper.terminationStatus == 0,
              gatekeeperOutput.contains("accepted"),
              gatekeeperOutput.contains("source=notarized developer id") else {
            throw ValidationError.gatekeeperRejected
        }

        var stapledTicketValidated = false
        let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        if fileManager.isExecutableFile(atPath: xcrunURL.path) {
            let stapler = try await commandRunner.run(
                executableURL: xcrunURL,
                arguments: ["stapler", "validate", appURL.path])
            let staplerOutput = stapler.combinedOutput.lowercased()
            if stapler.terminationStatus == 0,
               staplerOutput.contains("validate action worked") {
                stapledTicketValidated = true
            } else if !staplerOutput.contains("unable to find utility") {
                throw ValidationError.notarizationTicketInvalid
            }
        }

        return MacControlMCPTrustEvidence(
            bundleIdentifier: manifest.bundleIdentifier,
            teamIdentifier: manifest.teamIdentifier,
            signingIdentity: manifest.signingIdentity,
            hasHardenedRuntime: true,
            isUniversalBinary: true,
            gatekeeperAcceptedNotarization: true,
            stapledTicketValidated: stapledTicketValidated)
    }

    private static func hasLine(_ expected: String, in output: String) -> Bool {
        output.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(expected)
    }
}

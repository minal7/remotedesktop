import Foundation
import Security

struct MCPServerDefinition: Equatable, Sendable {
    let serverID: String
    let expectedServerName: String
    let expectedServerVersion: String
    let expectedProtocolVersion: String
    let appBundleName: String
    let executableName: String
    let executableSHA256: String
    let bundleIdentifier: String
    let teamIdentifier: String
}

struct MCPValidatedBinary: Equatable, Sendable {
    let definition: MCPServerDefinition
    let appBundleURL: URL
    let executableURL: URL
}

protocol MCPServerBinaryValidating: Sendable {
    func validate(
        binaryURL: URL,
        definition: MCPServerDefinition
    ) async throws -> MCPValidatedBinary
}

/// The app has no user-editable MCP server configuration. Supporting another
/// server requires a reviewed code change adding a pinned definition and
/// safety policy, rather than importing an arbitrary desktop MCP config.
enum MCPServerRegistry {
    /// In-process MCP server compiled into the signed host. Unlike curated
    /// sidecars it has no separately validated binary or user configuration.
    static let remoteDesktopMailServerID = RemoteDesktopMailMCP.serverID

    static let macControl = MCPServerDefinition(
        serverID: "io.github.AdelElo13.mac-control-mcp",
        expectedServerName: "mac-control-mcp",
        expectedServerVersion: "0.8.2",
        expectedProtocolVersion: "2024-11-05",
        appBundleName: "MacControlMCP.app",
        executableName: "MacControlMCP",
        executableSHA256: "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302",
        bundleIdentifier: "dev.macmcp.server",
        teamIdentifier: "A3W973JZ49")

    static let curatedServers = [macControl]
}

struct SystemMCPServerBinaryValidator: MCPServerBinaryValidating {
    func validate(
        binaryURL: URL,
        definition: MCPServerDefinition
    ) async throws -> MCPValidatedBinary {
        try Self.validateStructure(
            binaryURL: binaryURL,
            definition: definition,
            fileManager: .default)
    }

    static func validateStructure(
        binaryURL: URL,
        definition: MCPServerDefinition,
        fileManager: FileManager = .default
    ) throws -> MCPValidatedBinary {
        guard binaryURL.isFileURL, binaryURL.path.hasPrefix("/") else {
            throw MCPClientError.invalidBinary("An absolute local path is required.")
        }

        let suppliedURL = binaryURL.standardizedFileURL
        let executableURL = suppliedURL.resolvingSymlinksInPath()
        guard suppliedURL == executableURL else {
            throw MCPClientError.invalidBinary("Symbolic links are not allowed in the helper path.")
        }

        let macOSDirectory = executableURL.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appBundleURL = contentsDirectory.deletingLastPathComponent()
        guard executableURL.lastPathComponent == definition.executableName,
              macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              appBundleURL.lastPathComponent == definition.appBundleName else {
            throw MCPClientError.invalidBinary(
                "The executable is not inside the pinned app bundle layout.")
        }

        let resourceValues = try executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw MCPClientError.invalidBinary("The pinned executable is missing or is not executable.")
        }
        guard let executableData = try? Data(
            contentsOf: executableURL,
            options: [.mappedIfSafe]),
              MCPDigest.sha256(executableData)
                == definition.executableSHA256.lowercased() else {
            throw MCPClientError.invalidBinary(
                "The helper executable does not match the pinned release hash.")
        }

        guard let bundle = Bundle(url: appBundleURL),
              bundle.bundleIdentifier == definition.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == definition.expectedServerVersion,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
                == definition.executableName,
              bundle.executableURL?.standardizedFileURL.resolvingSymlinksInPath()
                == executableURL else {
            throw MCPClientError.invalidBinary("The app bundle metadata does not match the pinned release.")
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appBundleURL as CFURL,
            SecCSFlags(),
            &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw MCPClientError.invalidSignature("macOS could not inspect the app signature.")
        }

        let requirementText = "anchor apple generic and identifier \"\(definition.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(definition.teamIdentifier)\""
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw MCPClientError.invalidSignature("The pinned signature requirement is invalid.")
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement)
        guard validationStatus == errSecSuccess else {
            throw MCPClientError.invalidSignature(
                "The app is not signed by the pinned Developer ID team (status \(validationStatus)).")
        }

        return MCPValidatedBinary(
            definition: definition,
            appBundleURL: appBundleURL,
            executableURL: executableURL)
    }
}

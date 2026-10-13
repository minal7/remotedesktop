import Foundation
import ServiceManagement

enum SafariBridgeHelperServiceError: LocalizedError, Equatable {
    case helperMissingFromBundle
    case helperNotRegistered
    case helperRequiresApproval
    case statusUnavailable
    case registrationFailed(domain: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .helperMissingFromBundle:
            return "The Safari bridge helper is missing from the app bundle."
        case .helperNotRegistered:
            return "The Safari bridge helper is not registered."
        case .helperRequiresApproval:
            return "System Settings → General → Login Items & Extensions → allow Remote Desktop Host"
        case .statusUnavailable:
            return "The Safari bridge helper status is unavailable."
        case let .registrationFailed(domain, code):
            return "Safari bridge helper registration failed (\(domain), code \(code))."
        }
    }
}

@MainActor
enum SafariBridgeHelperService {
    enum Status: String {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unknown
    }

    @MainActor
    final class SettingsGate {
        private var didOpen = false

        func openOnce(_ open: () -> Void) {
            guard !didOpen else { return }
            didOpen = true
            open()
        }
    }

    private static let settingsGate = SettingsGate()

    static var statusName: String {
        statusName(for: SMAppService.agent(plistName: "LaunchAgent.plist").status)
    }

    static func statusName(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    static func ensureRegistered() throws -> String {
        let service = SMAppService.agent(plistName: "LaunchAgent.plist")
        return try ensureRegistered(
            status: { Self.map(service.status) },
            register: { try service.register() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() },
            settingsGate: settingsGate,
            verifiedBundleContainsHelper: bundledHelperIsPresent())
    }

    static func ensureRegistered(
        status: () -> Status,
        register: () throws -> Void,
        openSettings: () -> Void,
        settingsGate suppliedSettingsGate: SettingsGate? = nil,
        verifiedBundleContainsHelper: Bool = false
    ) throws -> String {
        let settingsGate = suppliedSettingsGate ?? SettingsGate()
        switch status() {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            settingsGate.openOnce(openSettings)
            throw SafariBridgeHelperServiceError.helperRequiresApproval
        case .unknown:
            throw SafariBridgeHelperServiceError.statusUnavailable
        case .notFound:
            guard verifiedBundleContainsHelper else {
                throw SafariBridgeHelperServiceError.helperMissingFromBundle
            }
            fallthrough
        case .notRegistered:
            do { try register() }
            catch {
                switch status() {
                case .requiresApproval:
                    settingsGate.openOnce(openSettings)
                    throw SafariBridgeHelperServiceError.helperRequiresApproval
                default:
                    break
                }
                let failure = error as NSError
                throw SafariBridgeHelperServiceError.registrationFailed(domain: failure.domain, code: failure.code)
            }
        }

        switch status() {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            settingsGate.openOnce(openSettings)
            throw SafariBridgeHelperServiceError.helperRequiresApproval
        case .notFound:
            throw SafariBridgeHelperServiceError.helperMissingFromBundle
        case .notRegistered:
            throw SafariBridgeHelperServiceError.helperNotRegistered
        case .unknown:
            throw SafariBridgeHelperServiceError.statusUnavailable
        }
    }

    private static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    private static func bundledHelperIsPresent(fileManager: FileManager = .default) -> Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let plistURL = bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/LaunchAgent.plist")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard plistURL.path.hasPrefix(bundleURL.path + "/"),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let program = dictionary["BundleProgram"] as? String,
              !program.isEmpty, !program.hasPrefix("/"),
              !program.split(separator: "/").contains("..") else { return false }
        let executableURL = bundleURL.appendingPathComponent(program).standardizedFileURL.resolvingSymlinksInPath()
        return executableURL.path.hasPrefix(bundleURL.path + "/")
            && fileManager.isExecutableFile(atPath: executableURL.path)
    }
}

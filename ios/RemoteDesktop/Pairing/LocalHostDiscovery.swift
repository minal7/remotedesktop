import CloudKit
import Foundation

struct LocalHostAdvertisement: Identifiable, Equatable {
    static let serviceType = "_remotedesktop._tcp."

    enum Source: String {
        case localNetwork
        case cloudKit
    }

    let hostname: String
    let code: String
    let source: Source
    let senderID: String?

    var id: String { senderID ?? "\(source.rawValue)|\(hostname)|\(code)" }

    static func serviceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
    }

    init(
        hostname: String,
        code: String,
        source: Source = .localNetwork,
        senderID: String? = nil
    ) {
        self.hostname = hostname
        self.code = code
        self.source = source
        self.senderID = senderID
    }

    static func parse(serviceName: String) -> LocalHostAdvertisement? {
        guard let open = serviceName.lastIndex(of: "["),
              let close = serviceName.lastIndex(of: "]"),
              open < close else {
            return nil
        }
        let hostname = serviceName[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let code = serviceName[serviceName.index(after: open)..<close]
        guard hostname.isEmpty == false,
              code.count == 6,
              code.allSatisfy(\.isNumber) else {
            return nil
        }
        return LocalHostAdvertisement(hostname: hostname, code: String(code))
    }
}

@MainActor
final class LocalHostDiscovery: NSObject, ObservableObject {
    @Published private(set) var hosts: [LocalHostAdvertisement] = []

    private let browser = NetServiceBrowser()
    private var services: [String: LocalHostAdvertisement] = [:]
    private var ckHosts: [LocalHostAdvertisement] = []
    private var ckTask: Task<Void, Never>?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        services.removeAll()
        ckHosts = []
        hosts = []
        guard !Self.isRunningUnitTests else {
            return
        }
        browser.searchForServices(ofType: LocalHostAdvertisement.serviceType, inDomain: "local.")

        startCloudKitPolling()
    }

    func stop() {
        browser.stop()
        ckTask?.cancel()
        ckTask = nil
        services.removeAll()
        ckHosts = []
        hosts = []
    }

    private func startCloudKitPolling() {
        ckTask?.cancel()
        ckTask = Task {
            while !Task.isCancelled {
                await fetchCloudKitHosts()
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    break
                }
            }
        }
    }

    private func fetchCloudKitHosts() async {
        do {
            let advertisements = try await CloudKitSignalingClient
                .fetchAvailableHostAdvertisements(
                    containerIdentifier: Config.cloudKitContainerIdentifier)
            self.ckHosts = advertisements.map {
                LocalHostAdvertisement(
                    hostname: $0.hostName,
                    code: $0.pairingCode,
                    source: .cloudKit,
                    senderID: $0.senderID)
            }
            self.syncHosts()
        } catch let error as CKError {
            if error.code == .unknownItem {
                // Schema hasn't been created yet in the database. Treat as empty list.
                self.ckHosts = []
                self.syncHosts()
            } else {
                // Other CloudKit-specific error, log it
                print("CloudKit discovery failed: \(error.localizedDescription)")
            }
        } catch {
            print("CloudKit discovery error: \(error.localizedDescription)")
        }
    }

    private func syncHosts() {
        var hostsByCode: [String: LocalHostAdvertisement] = [:]

        for localHost in services.values {
            hostsByCode[localHost.code] = localHost
        }

        for cloudHost in ckHosts where hostsByCode[cloudHost.code] == nil {
            hostsByCode[cloudHost.code] = cloudHost
        }

        let sorted = hostsByCode.values.sorted { lhs, rhs in
            if lhs.hostname == rhs.hostname {
                return lhs.code < rhs.code
            }
            return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }

        self.hosts = sorted
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

extension LocalHostDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            if let host = LocalHostAdvertisement.parse(serviceName: name) {
                self.services[name] = host
                if !moreComing { self.syncHosts() }
            }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            self.services.removeValue(forKey: name)
            if !moreComing { self.syncHosts() }
        }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            self.syncHosts()
        }
    }
}

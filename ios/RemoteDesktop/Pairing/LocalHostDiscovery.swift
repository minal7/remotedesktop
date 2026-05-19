import CloudKit
import Foundation

struct LocalHostAdvertisement: Identifiable, Equatable {
    static let serviceType = "_remotedesktop._tcp."

    let hostname: String
    let code: String

    var id: String { "\(hostname)|\(code)" }

    static func serviceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
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
        let container = CKContainer(identifier: Config.cloudKitContainerIdentifier)
        let database = container.privateCloudDatabase

        // Query active advertisements in the user's private database created within the last 5 minutes
        let cutoff = Date(timeIntervalSinceNow: -300)
        let predicate = NSPredicate(format: "createdAt > %@", cutoff as NSDate)
        let query = CKQuery(recordType: "HostAdvertisement", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let (matchResults, _) = try await database.records(matching: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 50)
            var fetched: [LocalHostAdvertisement] = []
            for (_, result) in matchResults {
                if case .success(let record) = result,
                   let hostname = record["hostName"] as? String,
                   let code = record["pairingCode"] as? String {
                    fetched.append(LocalHostAdvertisement(hostname: hostname, code: code))
                }
            }
            self.ckHosts = fetched
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
        // Collect mDNS hosts
        var allHosts = Array(services.values)

        // Merge CloudKit hosts, ensuring uniqueness by pairing code
        for ckHost in ckHosts {
            if !allHosts.contains(where: { $0.code == ckHost.code }) {
                allHosts.append(ckHost)
            }
        }

        // Sort by hostname then code
        let sorted = allHosts.sorted { lhs, rhs in
            if lhs.hostname == rhs.hostname {
                return lhs.code < rhs.code
            }
            return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }

        self.hosts = sorted
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

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

final class LocalHostDiscovery: NSObject, ObservableObject {
    @Published private(set) var hosts: [LocalHostAdvertisement] = []

    private let browser = NetServiceBrowser()
    private var services: [String: LocalHostAdvertisement] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        services.removeAll()
        hosts = []
        browser.searchForServices(ofType: LocalHostAdvertisement.serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.removeAll()
        hosts = []
    }

    private func syncHosts() {
        let sorted = services.values.sorted { lhs, rhs in
            if lhs.hostname == rhs.hostname {
                return lhs.code < rhs.code
            }
            return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }
        Task { @MainActor in
            self.hosts = sorted
        }
    }
}

extension LocalHostDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if let host = LocalHostAdvertisement.parse(serviceName: service.name) {
            services[service.name] = host
            if !moreComing { syncHosts() }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: service.name)
        if !moreComing { syncHosts() }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        syncHosts()
    }
}

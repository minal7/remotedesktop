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
    let computerUseCapability: ComputerUseCapability
    /// Bonjour TXT records improve nearby presentation, but they are not an
    /// authenticated statement about which CloudKit environment the app can
    /// reach. Computer Use remains gated until the same sender and pairing
    /// code are present in the private CloudKit snapshot.
    let hasAuthenticatedCloudMatch: Bool

    var canOfferComputerUse: Bool {
        hasAuthenticatedCloudMatch && senderID?.isEmpty == false
    }

    // A single Mac can briefly advertise more than one pairing code when an
    // older host copy is still shutting down. Keep SwiftUI identity unique
    // until CloudKit selects the authoritative code for that Mac.
    var id: String {
        if let senderID, !senderID.isEmpty {
            return "\(senderID)|\(code)"
        }
        return "\(source.rawValue)|\(hostname.lowercased())|\(code)"
    }

    static func serviceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
    }

    init(
        hostname: String,
        code: String,
        source: Source = .localNetwork,
        senderID: String? = nil,
        computerUseCapability: ComputerUseCapability = .unavailable,
        hasAuthenticatedCloudMatch: Bool? = nil
    ) {
        self.hostname = hostname
        self.code = code
        self.source = source
        self.senderID = senderID
        self.computerUseCapability = computerUseCapability
        self.hasAuthenticatedCloudMatch = hasAuthenticatedCloudMatch
            ?? (source == .cloudKit && senderID?.isEmpty == false)
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

    /// Preserves the legacy `Computer Name [123456]` contract while adding
    /// validated identity and AI readiness when a current host publishes a
    /// TXT record. Invalid or future metadata never hides a usable legacy row.
    static func parse(
        serviceName: String,
        txtRecordData: Data?
    ) -> LocalHostAdvertisement? {
        guard let legacy = parse(serviceName: serviceName),
              let txtRecordData,
              let metadata = LocalHostBonjourMetadata.decode(
                txtRecordData: txtRecordData) else {
            return parse(serviceName: serviceName)
        }
        return LocalHostAdvertisement(
            hostname: legacy.hostname,
            code: legacy.code,
            source: .localNetwork,
            senderID: metadata.senderID,
            computerUseCapability: metadata.computerUseCapability)
    }
}

@MainActor
final class LocalHostDiscovery: NSObject, ObservableObject {
    @Published private(set) var hosts: [LocalHostAdvertisement] = []

    private let browser = NetServiceBrowser()
    private var services: [String: LocalHostAdvertisement] = [:]
    private var serviceInstances: [String: NetService] = [:]
    private var ckHosts: [LocalHostAdvertisement] = []
    private var ckTask: Task<Void, Never>?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stopNearbyResolution()
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
        stopNearbyResolution()
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
                    senderID: $0.senderID,
                    computerUseCapability: $0.computerUseCapability)
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
        hosts = Self.mergedHosts(
            localHosts: Array(services.values),
            cloudHosts: ckHosts)
    }

    /// Deterministic merge kept separate from the browser callbacks so the
    /// legacy, matching-identity, and conflicting-identity cases stay tested.
    nonisolated static func mergedHosts(
        localHosts: [LocalHostAdvertisement],
        cloudHosts: [LocalHostAdvertisement]
    ) -> [LocalHostAdvertisement] {
        struct AuthenticatedIdentity: Hashable {
            let senderID: String
            let code: String
        }

        func authenticatedIdentity(
            for host: LocalHostAdvertisement
        ) -> AuthenticatedIdentity? {
            guard let senderID = host.senderID, !senderID.isEmpty else {
                return nil
            }
            return AuthenticatedIdentity(senderID: senderID, code: host.code)
        }

        // Start with every authenticated Mac. Pairing codes are intentionally
        // not dictionary keys: two Macs can independently choose the same
        // six-digit code and must remain separate rows.
        var mergedByIdentity: [String: LocalHostAdvertisement] = [:]
        let authenticatedCloudHosts = cloudHosts.compactMap { host -> LocalHostAdvertisement? in
            guard host.source == .cloudKit,
                  host.senderID?.isEmpty == false else {
                return nil
            }
            return LocalHostAdvertisement(
                hostname: host.hostname,
                code: host.code,
                source: .cloudKit,
                senderID: host.senderID,
                computerUseCapability: host.computerUseCapability,
                hasAuthenticatedCloudMatch: true)
        }
        for host in authenticatedCloudHosts {
            mergedByIdentity[host.id] = host
        }

        // Keep malformed/legacy CloudKit rows visible for remote control, but
        // never promote them to authenticated Computer Use rows.
        for host in cloudHosts where host.senderID?.isEmpty != false {
            let unauthenticated = LocalHostAdvertisement(
                hostname: host.hostname,
                code: host.code,
                source: .cloudKit,
                senderID: nil,
                computerUseCapability: host.computerUseCapability,
                hasAuthenticatedCloudMatch: false)
            mergedByIdentity[unauthenticated.id] = unauthenticated
        }

        let cloudByIdentity = Dictionary(
            authenticatedCloudHosts.compactMap { host -> (AuthenticatedIdentity, LocalHostAdvertisement)? in
                guard let identity = authenticatedIdentity(for: host) else {
                    return nil
                }
                return (identity, host)
            },
            uniquingKeysWith: { first, _ in first })
        let cloudSenderIDs = Set(authenticatedCloudHosts.compactMap(\.senderID))
        let cloudByCode = Dictionary(
            grouping: authenticatedCloudHosts,
            by: \.code)
        let legacyLocalCountByCode = Dictionary(
            grouping: localHosts.filter { $0.senderID?.isEmpty != false },
            by: \.code).mapValues(\.count)

        for localHost in localHosts {
            if let localIdentity = authenticatedIdentity(for: localHost) {
                if cloudByIdentity[localIdentity] != nil {
                    // Exact private-CloudKit identity confirms the nearby
                    // advertisement belongs to the reachable environment.
                    // Prefer its monitored capability for prompt progress.
                    let authenticatedNearby = LocalHostAdvertisement(
                        hostname: localHost.hostname,
                        code: localHost.code,
                        source: .localNetwork,
                        senderID: localHost.senderID,
                        computerUseCapability: localHost.computerUseCapability,
                        hasAuthenticatedCloudMatch: true)
                    mergedByIdentity[authenticatedNearby.id] = authenticatedNearby
                } else if cloudSenderIDs.contains(localIdentity.senderID) {
                    // The same Mac is authenticated under another code in this
                    // CloudKit environment. Hide the wrong-environment nearby
                    // instance instead of presenting a connection that cannot
                    // complete.
                    continue
                } else {
                    // A signed-looking Bonjour TXT record is still only local
                    // network input. Preserve remote control discovery while
                    // keeping Computer Use unavailable until CloudKit agrees.
                    let nearbyOnly = LocalHostAdvertisement(
                        hostname: localHost.hostname,
                        code: localHost.code,
                        source: .localNetwork,
                        senderID: localHost.senderID,
                        computerUseCapability: localHost.computerUseCapability,
                        hasAuthenticatedCloudMatch: false)
                    mergedByIdentity[nearbyOnly.id] = nearbyOnly
                }
                continue
            }

            let cloudMatches = cloudByCode[localHost.code] ?? []
            let hasUniqueLegacyPair = cloudMatches.count == 1
                && legacyLocalCountByCode[localHost.code] == 1
            if hasUniqueLegacyPair, let cloudHost = cloudMatches.first {
                // Legacy Bonjour has no sender identity. Retain compatibility
                // only when one local row maps to exactly one authenticated
                // CloudKit row for this code.
                let enrichedLegacy = LocalHostAdvertisement(
                    hostname: localHost.hostname,
                    code: localHost.code,
                    source: .localNetwork,
                    senderID: cloudHost.senderID,
                    computerUseCapability: cloudHost.computerUseCapability,
                    hasAuthenticatedCloudMatch: true)
                mergedByIdentity[enrichedLegacy.id] = enrichedLegacy
            } else {
                let nearbyOnly = LocalHostAdvertisement(
                    hostname: localHost.hostname,
                    code: localHost.code,
                    source: .localNetwork,
                    senderID: nil,
                    computerUseCapability: localHost.computerUseCapability,
                    hasAuthenticatedCloudMatch: false)
                mergedByIdentity[nearbyOnly.id] = nearbyOnly
            }
        }

        return mergedByIdentity.values.sorted { lhs, rhs in
            if lhs.hostname == rhs.hostname {
                if lhs.code == rhs.code {
                    return lhs.id < rhs.id
                }
                return lhs.code < rhs.code
            }
            return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }
    }

    private func addNearbyService(_ service: NetService, moreComing: Bool) {
        let name = service.name
        guard let advertisement = LocalHostAdvertisement.parse(
            serviceName: name,
            txtRecordData: service.txtRecordData()) else {
            return
        }

        if let previous = serviceInstances.updateValue(service, forKey: name),
           previous !== service {
            previous.stopMonitoring()
            previous.stop()
            previous.delegate = nil
        }
        services[name] = advertisement
        service.delegate = self
        service.resolve(withTimeout: 5)
        if !moreComing {
            syncHosts()
        }
    }

    private func resolvedNearbyService(
        _ service: NetService,
        txtRecordData: Data?
    ) {
        let name = service.name
        guard serviceInstances[name] === service,
              let advertisement = LocalHostAdvertisement.parse(
                serviceName: name,
                txtRecordData: txtRecordData) else {
            return
        }
        services[name] = advertisement
        syncHosts()
    }

    private func stopNearbyResolution() {
        for service in serviceInstances.values {
            service.stopMonitoring()
            service.stop()
            service.delegate = nil
        }
        serviceInstances.removeAll()
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

extension LocalHostDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.addNearbyService(service, moreComing: moreComing)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            if let retained = self.serviceInstances.removeValue(forKey: name) {
                retained.stopMonitoring()
                retained.stop()
                retained.delegate = nil
            }
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

extension LocalHostDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let txtRecordData = sender.txtRecordData()
        Task { @MainActor in
            sender.startMonitoring()
            self.resolvedNearbyService(sender, txtRecordData: txtRecordData)
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didUpdateTXTRecord data: Data
    ) {
        Task { @MainActor in
            self.resolvedNearbyService(sender, txtRecordData: data)
        }
    }
}

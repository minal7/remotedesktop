import CloudKit
import CryptoKit
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
    /// Resolved LAN endpoint for the TLS computer-use broker. This is only a
    /// route; the separately enrolled Keychain credential authenticates it.
    let localEndpoint: LocalComputerUseEndpoint?
    /// Non-secret SHA-256 selector for the host's local TLS credential.
    let localCredentialID: String?
    /// Bonjour TXT records improve nearby presentation, but they are not an
    /// authenticated statement about which CloudKit environment the app can
    /// reach. Computer Use remains gated until the same sender and pairing
    /// code are present in the private CloudKit snapshot.
    let hasAuthenticatedCloudMatch: Bool
    /// Opaque owner of the private CloudKit snapshot that authenticated this
    /// row. Bonjour never supplies or overrides this value.
    let accountBinding: CloudKitAccountBinding?

    var canOfferComputerUse: Bool {
        guard senderID?.isEmpty == false else { return false }
        return hasAuthenticatedCloudMatch
    }

    var canOfferLocalComputerUse: Bool {
        hasAuthenticatedCloudMatch
            && accountBinding != nil
            && senderID?.isEmpty == false
            && localEndpoint?.isValid == true
            && localCredentialID.map(Self.isValidLocalCredentialID) == true
    }

    /// A stable, non-secret presentation token derived from the authenticated
    /// host identity. Computer names are not unique, while the private routing
    /// binding must never be shown as a pairing code. This short digest lets a
    /// person and VoiceOver distinguish two same-name Macs without exposing
    /// the routing binding or the full sender identifier.
    var presentationDiscriminator: String? {
        guard let senderID,
              !senderID.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(senderID.utf8))
        let token = digest.prefix(4)
            .map { String(format: "%02X", $0) }
            .joined()
        let midpoint = token.index(token.startIndex, offsetBy: 4)
        return "ID \(token[..<midpoint])-\(token[midpoint...])"
    }

    var accessibilityDisplayName: String {
        guard let presentationDiscriminator else { return hostname }
        return "\(hostname), \(presentationDiscriminator)"
    }

    // A single Mac can briefly advertise more than one session binding when an
    // older host copy is still shutting down. Keep SwiftUI identity unique
    // until CloudKit selects the authoritative code for that Mac.
    var id: String {
        if let senderID, !senderID.isEmpty {
            return "\(senderID)|\(code)"
        }
        return "\(source.rawValue)|\(hostname.lowercased())|\(code)"
    }

    static func legacyServiceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
    }

    init(
        hostname: String,
        code: String,
        source: Source = .localNetwork,
        senderID: String? = nil,
        computerUseCapability: ComputerUseCapability = .unavailable,
        hasAuthenticatedCloudMatch: Bool? = nil,
        accountBinding: CloudKitAccountBinding? = nil,
        localEndpoint: LocalComputerUseEndpoint? = nil,
        localCredentialID: String? = nil
    ) {
        self.hostname = hostname
        self.code = code
        self.source = source
        self.senderID = senderID
        self.computerUseCapability = computerUseCapability
        self.localEndpoint = localEndpoint
        self.localCredentialID = localCredentialID
        self.hasAuthenticatedCloudMatch = hasAuthenticatedCloudMatch
            ?? (source == .cloudKit && senderID?.isEmpty == false)
        self.accountBinding = accountBinding
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

    /// Current hosts keep the browser-visible service name to the computer
    /// name and carry the internal routing binding in bounded TXT metadata.
    /// Legacy `Computer Name [123456]` hosts remain readable during upgrades.
    /// Neither form authenticates the row; exact private-CloudKit matching is
    /// still required before any connection or Computer Use action is enabled.
    static func parse(
        serviceName: String,
        txtRecordData: Data?,
        localEndpoint: LocalComputerUseEndpoint? = nil
    ) -> LocalHostAdvertisement? {
        let legacy = parse(serviceName: serviceName)
        guard let txtRecordData,
              let metadata = LocalHostBonjourMetadata.decode(
                txtRecordData: txtRecordData) else {
            return legacy
        }

        let hostname: String
        let code: String
        if let routingBinding = metadata.routingBinding {
            if let legacy {
                guard legacy.code == routingBinding else { return nil }
                hostname = legacy.hostname
            } else {
                guard let plainHostname = validatedPlainServiceName(
                    serviceName) else {
                    return nil
                }
                hostname = plainHostname
            }
            code = routingBinding
        } else {
            guard let legacy else { return nil }
            hostname = legacy.hostname
            code = legacy.code
        }
        return LocalHostAdvertisement(
            hostname: hostname,
            code: code,
            source: .localNetwork,
            senderID: metadata.senderID,
            computerUseCapability: metadata.computerUseCapability,
            localEndpoint: localEndpoint,
            localCredentialID: metadata.localCredentialID)
    }

    static func validatedPlainServiceName(_ value: String) -> String? {
        let hostname = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !hostname.isEmpty,
              hostname.utf8.count <= 255,
              hostname.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.newlines.contains(scalar)
              }) else {
            return nil
        }
        return hostname
    }

    static func shouldResolveBonjourService(
        serviceName: String,
        txtRecordData: Data?
    ) -> Bool {
        parse(
            serviceName: serviceName,
            txtRecordData: txtRecordData) != nil
            || validatedPlainServiceName(serviceName) != nil
    }

    static func isValidLocalCredentialID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x61 && byte <= 0x66)
            }
    }
}

/// Tracks each DNS-SD callback by object identity. Service names are
/// presentation values and can collide; a removal callback for one instance
/// must never withdraw another instance that happens to have the same name.
struct LocalHostNearbyServiceStore {
    private(set) var instances: [ObjectIdentifier: NetService] = [:]
    private(set) var advertisements:
        [ObjectIdentifier: LocalHostAdvertisement] = [:]

    var hosts: [LocalHostAdvertisement] {
        Array(advertisements.values)
    }

    mutating func retain(_ service: NetService) {
        instances[ObjectIdentifier(service)] = service
    }

    func contains(_ service: NetService) -> Bool {
        instances[ObjectIdentifier(service)] === service
    }

    @discardableResult
    mutating func setAdvertisement(
        _ advertisement: LocalHostAdvertisement,
        for service: NetService
    ) -> Bool {
        let key = ObjectIdentifier(service)
        guard instances[key] === service else { return false }
        advertisements[key] = advertisement
        return true
    }

    mutating func remove(_ service: NetService) -> NetService? {
        let key = ObjectIdentifier(service)
        guard instances[key] === service else { return nil }
        advertisements[key] = nil
        return instances.removeValue(forKey: key)
    }

    mutating func removeAll() -> [NetService] {
        let retained = Array(instances.values)
        instances.removeAll()
        advertisements.removeAll()
        return retained
    }
}

enum AutomaticLocalComputerUsePairingState: Equatable {
    case pairing
    case failed(String)
}

enum LocalCloudAccountPairingStatus: Equatable, CaseIterable {
    case signInRequired
    case accessRestricted
    case temporarilyUnavailable
    case couldNotDetermine
    case secureStorageUnavailable

    var title: String {
        switch self {
        case .signInRequired:
            return "Sign in to your Apple Account"
        case .accessRestricted:
            return "Allow iCloud access"
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable"
        case .couldNotDetermine:
            return "Confirm iCloud is available"
        case .secureStorageUnavailable:
            return "Secure pairing storage is unavailable"
        }
    }

    var guidance: String {
        switch self {
        case .signInRequired:
            return "Open Settings, sign in to iCloud with the same Apple Account as your Mac, then return here."
        case .accessRestricted:
            return "Check Screen Time or device-management restrictions for iCloud, then return here."
        case .temporarilyUnavailable:
            return "Check your internet connection and keep this screen open. Pairing will retry automatically."
        case .couldNotDetermine:
            return "Open Settings, confirm you’re signed in to iCloud, and check your internet connection. Pairing will retry automatically."
        case .secureStorageUnavailable:
            return "Restart this app and try again. If this continues, restart your device; pairing stays disabled until secure storage is available."
        }
    }

    var systemImage: String {
        switch self {
        case .signInRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .accessRestricted:
            return "lock.icloud"
        case .temporarilyUnavailable:
            return "icloud.slash"
        case .couldNotDetermine:
            return "exclamationmark.icloud"
        case .secureStorageUnavailable:
            return "key.fill"
        }
    }

    /// A closed reducer keeps UI copy independent of CloudKit diagnostics and
    /// ensures a positive account binding always clears an earlier warning.
    static func updated(
        after resolution: LocalCloudAccountResolutionUpdate,
        hasUsableAuthenticatedSnapshot: Bool
    ) -> Self? {
        guard !hasUsableAuthenticatedSnapshot else { return nil }
        switch resolution {
        case .bound:
            return nil
        case .failed(.noAccount):
            return .signInRequired
        case .failed(.restricted):
            return .accessRestricted
        case .failed(.temporarilyUnavailable):
            return .temporarilyUnavailable
        case .failed(.couldNotDetermine):
            return .couldNotDetermine
        case .secureStorageUnavailable:
            return .secureStorageUnavailable
        }
    }
}

enum LocalCloudAccountResolutionUpdate: Equatable {
    case bound
    case failed(CloudKitAccountBindingResolutionError)
    case secureStorageUnavailable
}

@MainActor
enum LocalCloudAccountBindingPolicy {
    private struct InProcessConfirmation {
        let binding: CloudKitAccountBinding
        let generation: UInt64
        let expiresAt: Date
    }

    private static let transientGraceInterval: TimeInterval = 5 * 60
    private static var accountGeneration: UInt64 = 0
    private static var inProcessConfirmation: InProcessConfirmation?

    /// Revalidates a LAN action against the current CloudKit owner. Transient
    /// fallback is available only after this process positively resolved the
    /// same owner in the current account generation, and only for a short
    /// grace period. A device-local Keychain marker alone is never sufficient
    /// on cold launch or after an account-change notification.
    static func validate(
        _ expected: CloudKitAccountBinding
    ) async throws {
        let store = LocalComputerUseCredentialStore()
        let validationGeneration = accountGeneration
        do {
            let current = try await CloudKitAccountBinding.current(
                containerIdentifier: Config.cloudKitContainerIdentifier)
            guard validationGeneration == accountGeneration else {
                throw CloudKitAccountBindingResolutionError.couldNotDetermine
            }
            // Record every positive resolution before comparing it with a
            // potentially stale route. Otherwise a mismatch could leave the
            // old owner marker available to a later transient fallback.
            try store.setConfirmedAccountBinding(current)
            inProcessConfirmation = InProcessConfirmation(
                binding: current,
                generation: accountGeneration,
                expiresAt: Date().addingTimeInterval(transientGraceInterval))
            guard current == expected else {
                throw LocalComputerUseCloudPairingError.accountMismatch
            }
        } catch let resolution as CloudKitAccountBindingResolutionError {
            guard validationGeneration == accountGeneration else {
                throw resolution
            }
            if resolution.preservesConfirmedBinding,
               let confirmation = inProcessConfirmation,
               confirmation.binding == expected,
               confirmation.generation == accountGeneration,
               confirmation.expiresAt >= Date(),
               try store.confirmedAccountBinding() == expected {
                return
            }
            if !resolution.preservesConfirmedBinding {
                inProcessConfirmation = nil
                try? store.clearConfirmedAccountBinding()
            }
            throw resolution
        }
    }

    /// Called synchronously from every CloudKit account-change observer before
    /// any suspended validation is allowed to resume.
    static func invalidateForAccountChange() {
        accountGeneration &+= 1
        inProcessConfirmation = nil
    }
}

@MainActor
final class LocalHostDiscovery: NSObject, ObservableObject {
    @Published private(set) var hosts: [LocalHostAdvertisement] = []
    @Published private(set) var automaticPairingStates:
        [String: AutomaticLocalComputerUsePairingState] = [:]
    @Published private(set) var accountPairingStatus:
        LocalCloudAccountPairingStatus?

    private let browser = NetServiceBrowser()
    private var nearbyServices = LocalHostNearbyServiceStore()
    private var ckHosts: [LocalHostAdvertisement] = []
    private var ckTask: Task<Void, Never>?
    private let localCredentialStore = LocalComputerUseCredentialStore()
    private var activeAccountBinding: CloudKitAccountBinding?
    private var accountChangeObserver: NSObjectProtocol?
    private var isDiscovering = false
    /// Invalidates every suspended CloudKit fetch and credential exchange when
    /// discovery restarts or the signed-in Apple Account changes. Task
    /// cancellation alone is insufficient because CloudKit may still return a
    /// result after cancellation.
    private var discoveryGeneration: UInt64 = 0
    private struct AutomaticPairingTaskContext {
        let routeIdentity: String
        let task: Task<Void, Never>
    }
    private var automaticPairingTasks:
        [String: AutomaticPairingTaskContext] = [:]
    private var automaticPairingRetryAfter: [String: Date] = [:]

    override init() {
        super.init()
        browser.delegate = self
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleCloudKitAccountChanged()
            }
        }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    func start() {
        discoveryGeneration &+= 1
        isDiscovering = true
        automaticPairingTasks.values.forEach { $0.task.cancel() }
        automaticPairingTasks.removeAll()
        stopNearbyResolution()
        ckHosts = []
        activeAccountBinding = nil
        hosts = []
        accountPairingStatus = nil
        automaticPairingStates = [:]
        automaticPairingRetryAfter = [:]
        guard !Self.isRunningUnitTests else {
            isDiscovering = false
            return
        }
        browser.searchForServices(ofType: LocalHostAdvertisement.serviceType, inDomain: "local.")

        startCloudKitPolling()
    }

    func stop() {
        discoveryGeneration &+= 1
        isDiscovering = false
        browser.stop()
        ckTask?.cancel()
        ckTask = nil
        automaticPairingTasks.values.forEach { $0.task.cancel() }
        automaticPairingTasks.removeAll()
        automaticPairingStates = [:]
        automaticPairingRetryAfter = [:]
        stopNearbyResolution()
        ckHosts = []
        activeAccountBinding = nil
        hosts = []
        accountPairingStatus = nil
    }

    private func startCloudKitPolling() {
        ckTask?.cancel()
        let generation = discoveryGeneration
        ckTask = Task {
            while isCurrentDiscoveryGeneration(generation) {
                await fetchCloudKitHosts(generation: generation)
                guard isCurrentDiscoveryGeneration(generation) else { break }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    break
                }
            }
        }
    }

    private func fetchCloudKitHosts(generation: UInt64) async {
        let accountBinding: CloudKitAccountBinding
        do {
            accountBinding = try await CloudKitAccountBinding.current(
                containerIdentifier: Config.cloudKitContainerIdentifier)
        } catch let resolution as CloudKitAccountBindingResolutionError {
            guard isCurrentDiscoveryGeneration(generation) else { return }
            handleAccountResolutionFailure(
                resolution,
                generation: generation)
            return
        } catch {
            guard isCurrentDiscoveryGeneration(generation) else { return }
            invalidateAccountBoundDiscovery()
            updateAccountPairingStatus(
                after: .failed(.couldNotDetermine))
            print("CloudKit account binding could not be resolved: \(error.localizedDescription)")
            return
        }
        guard isCurrentDiscoveryGeneration(generation),
              persistConfirmedAccountBinding(
                accountBinding,
                generation: generation) else { return }
        updateAccountPairingStatus(after: .bound)

        guard isCurrentDiscoveryGeneration(generation) else { return }
        if activeAccountBinding != accountBinding {
            invalidateAccountBoundDiscovery()
            activeAccountBinding = accountBinding
        }

        do {
            let advertisements = try await CloudKitSignalingClient
                .fetchAvailableHostAdvertisements(
                    containerIdentifier: Config.cloudKitContainerIdentifier)
            guard isCurrentDiscoveryGeneration(generation) else { return }
            // Re-resolve after the private-database query. Never label a
            // snapshot with an account that changed while the query ran.
            let verifiedBinding = try await CloudKitAccountBinding.current(
                containerIdentifier: Config.cloudKitContainerIdentifier)
            guard isCurrentDiscoveryGeneration(generation) else { return }
            guard verifiedBinding == accountBinding else {
                invalidateAccountBoundDiscovery()
                return
            }
            guard persistConfirmedAccountBinding(
                verifiedBinding,
                generation: generation) else { return }
            updateAccountPairingStatus(after: .bound)
            self.ckHosts = advertisements.map {
                LocalHostAdvertisement(
                    hostname: $0.hostName,
                    code: $0.pairingCode,
                    source: .cloudKit,
                    senderID: $0.senderID,
                    computerUseCapability: $0.computerUseCapability,
                    accountBinding: verifiedBinding)
            }
            self.syncHosts()
        } catch let resolution as CloudKitAccountBindingResolutionError {
            guard isCurrentDiscoveryGeneration(generation) else { return }
            handleAccountResolutionFailure(
                resolution,
                generation: generation)
        } catch let error as CKError {
            guard isCurrentDiscoveryGeneration(generation) else { return }
            if error.code == .unknownItem {
                // Schema hasn't been created yet in the database. Treat as empty list.
                self.ckHosts = []
                self.syncHosts()
            } else if Self.preservesAuthenticatedSnapshot(error) {
                // A verified owner may keep using its last exact snapshot
                // during a short network/service outage.
                self.syncHosts()
            } else {
                // Authentication, permission, and malformed-container errors
                // cannot leave an old private-database route actionable.
                self.invalidateAccountBoundDiscovery()
                print("CloudKit discovery failed: \(error.localizedDescription)")
            }
        } catch {
            guard isCurrentDiscoveryGeneration(generation) else { return }
            self.invalidateAccountBoundDiscovery()
            print("CloudKit discovery error: \(error.localizedDescription)")
        }
    }

    private nonisolated static func preservesAuthenticatedSnapshot(
        _ error: CKError
    ) -> Bool {
        switch error.code {
        case .accountTemporarilyUnavailable, .networkUnavailable,
             .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost:
            return true
        default:
            return false
        }
    }

    private func handleCloudKitAccountChanged() {
        LocalCloudAccountBindingPolicy.invalidateForAccountChange()
        guard isDiscovering else { return }
        discoveryGeneration &+= 1
        // The notification itself does not reveal the new owner. Hide every
        // account-bound route first, then require a positive re-resolution.
        accountPairingStatus = nil
        invalidateAccountBoundDiscovery()
        ckTask?.cancel()
        startCloudKitPolling()
    }

    private func handleAccountResolutionFailure(
        _ resolution: CloudKitAccountBindingResolutionError,
        generation: UInt64
    ) {
        guard isCurrentDiscoveryGeneration(generation) else { return }
        if resolution.preservesConfirmedBinding {
            do {
                let confirmed = try localCredentialStore
                    .confirmedAccountBinding()
                if confirmed == activeAccountBinding,
                   activeAccountBinding != nil {
                    // Keep only the already authenticated snapshot. A
                    // transient outage cannot authenticate a new Bonjour row.
                    syncHosts()
                    updateAccountPairingStatus(after: .failed(resolution))
                    return
                }
            } catch {
                print("Stored Apple Account binding could not be verified: \(error.localizedDescription)")
            }
        } else {
            do {
                try localCredentialStore.clearConfirmedAccountBinding()
            } catch {
                print("Stored Apple Account binding could not be cleared: \(error.localizedDescription)")
            }
        }
        invalidateAccountBoundDiscovery()
        updateAccountPairingStatus(after: .failed(resolution))
    }

    private func updateAccountPairingStatus(
        after resolution: LocalCloudAccountResolutionUpdate
    ) {
        accountPairingStatus = LocalCloudAccountPairingStatus.updated(
            after: resolution,
            hasUsableAuthenticatedSnapshot:
                hasUsableAuthenticatedCloudSnapshot)
    }

    /// A resolved CloudKit owner is not actionable unless its opaque binding
    /// can also be persisted in Keychain. Fail closed and surface a bounded
    /// recovery action instead of leaving an indefinite discovery spinner.
    private func persistConfirmedAccountBinding(
        _ binding: CloudKitAccountBinding,
        generation: UInt64
    ) -> Bool {
        do {
            try localCredentialStore.setConfirmedAccountBinding(binding)
            return true
        } catch {
            guard isCurrentDiscoveryGeneration(generation) else { return false }
            invalidateAccountBoundDiscovery()
            updateAccountPairingStatus(after: .secureStorageUnavailable)
            print("Apple Account binding could not be persisted securely: \(error.localizedDescription)")
            return false
        }
    }

    private var hasUsableAuthenticatedCloudSnapshot: Bool {
        guard let activeAccountBinding else { return false }
        return ckHosts.contains { host in
            host.source == .cloudKit
                && host.senderID?.isEmpty == false
                && host.accountBinding == activeAccountBinding
        }
    }

    private func isCurrentDiscoveryGeneration(_ generation: UInt64) -> Bool {
        isDiscovering
            && discoveryGeneration == generation
            && !Task.isCancelled
    }

    private func invalidateAccountBoundDiscovery() {
        automaticPairingTasks.values.forEach { $0.task.cancel() }
        automaticPairingTasks.removeAll()
        automaticPairingStates = [:]
        automaticPairingRetryAfter = [:]
        activeAccountBinding = nil
        ckHosts = []
        syncHosts()
    }

    private func syncHosts() {
        hosts = Self.mergedHosts(
            localHosts: nearbyServices.hosts,
            cloudHosts: ckHosts)
        reconcileAutomaticLocalPairing()
    }

    func automaticPairingState(
        for host: LocalHostAdvertisement
    ) -> AutomaticLocalComputerUsePairingState? {
        guard let hostID = host.senderID else { return nil }
        return automaticPairingStates[hostID]
    }

    func retryAutomaticPairing(for host: LocalHostAdvertisement) {
        guard let hostID = host.senderID else { return }
        automaticPairingRetryAfter[hostID] = nil
        automaticPairingStates[hostID] = .pairing
        startAutomaticPairing(for: host)
    }

    private func reconcileAutomaticLocalPairing() {
        var candidateByHostID: [String: LocalHostAdvertisement] = [:]
        for host in hosts where host.hasAuthenticatedCloudMatch {
            guard let hostID = host.senderID,
                  host.canOfferLocalComputerUse,
                  let credentialID = host.localCredentialID,
                  let accountBinding = host.accountBinding else {
                continue
            }
            if localCredentialStore.clientCredential(
                hostID: hostID,
                credentialID: credentialID,
                accountBinding: accountBinding) != nil {
                automaticPairingTasks.removeValue(forKey: hostID)?.task.cancel()
                automaticPairingStates[hostID] = nil
                automaticPairingRetryAfter[hostID] = nil
                continue
            }
            // A merged nearby + CloudKit row is preferred over a cloud-only
            // duplicate because only it carries the LAN endpoint/fingerprint.
            if candidateByHostID[hostID] == nil
                || host.localEndpoint != nil {
                candidateByHostID[hostID] = host
            }
        }

        let activeHostIDs = Set(candidateByHostID.keys)
        for (hostID, context) in automaticPairingTasks
            where !activeHostIDs.contains(hostID) {
            context.task.cancel()
            automaticPairingTasks[hostID] = nil
            automaticPairingStates[hostID] = nil
            automaticPairingRetryAfter[hostID] = nil
        }

        for (hostID, host) in candidateByHostID {
            let routeIdentity = automaticPairingRouteIdentity(for: host)
            if let active = automaticPairingTasks[hostID] {
                if active.routeIdentity == routeIdentity { continue }
                active.task.cancel()
                automaticPairingTasks[hostID] = nil
            }
            if let retryAfter = automaticPairingRetryAfter[hostID],
               retryAfter > Date() {
                continue
            }
            startAutomaticPairing(for: host)
        }
    }

    private func startAutomaticPairing(
        for host: LocalHostAdvertisement
    ) {
        guard host.hasAuthenticatedCloudMatch,
              let hostID = host.senderID,
              let credentialID = host.localCredentialID,
              let accountBinding = host.accountBinding,
              host.localEndpoint?.isValid == true else {
            return
        }
        let routeIdentity = automaticPairingRouteIdentity(for: host)
        let generation = discoveryGeneration
        if let active = automaticPairingTasks[hostID],
           active.routeIdentity == routeIdentity {
            return
        }
        automaticPairingTasks.removeValue(forKey: hostID)?.task.cancel()
        automaticPairingStates[hostID] = .pairing

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let senderID = DeviceIdentity.get()
                guard !senderID.isEmpty else {
                    throw SignalingError.transport(
                        "Secure device identity is unavailable. Unlock this device and try again.")
                }
                let exchange = CloudKitLocalComputerUsePairing(
                    containerIdentifier: Config.cloudKitContainerIdentifier,
                    senderID: senderID)
                let credential = try await exchange.requestCredential(
                    hostID: hostID,
                    pairingCode: host.code,
                    expectedCredentialID: credentialID,
                    accountBinding: accountBinding)
                guard isCurrentDiscoveryGeneration(generation),
                      activeAccountBinding == accountBinding,
                      automaticPairingTasks[hostID]?.routeIdentity
                        == routeIdentity else {
                    return
                }
                try localCredentialStore.saveClientCredential(
                    credential,
                    hostID: hostID,
                    accountBinding: accountBinding)
                guard isCurrentDiscoveryGeneration(generation),
                      activeAccountBinding == accountBinding,
                      automaticPairingTasks[hostID]?.routeIdentity
                        == routeIdentity else {
                    return
                }
                automaticPairingTasks[hostID] = nil
                automaticPairingStates[hostID] = nil
                automaticPairingRetryAfter[hostID] = nil
                // Republish the current rows so views that derive readiness
                // from Keychain immediately replace the progress affordance.
                hosts = Self.mergedHosts(
                    localHosts: nearbyServices.hosts,
                    cloudHosts: ckHosts)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentDiscoveryGeneration(generation),
                      activeAccountBinding == accountBinding,
                      automaticPairingTasks[hostID]?.routeIdentity
                        == routeIdentity else {
                    return
                }
                automaticPairingTasks[hostID] = nil
                automaticPairingRetryAfter[hostID] = Date()
                    .addingTimeInterval(6)
                automaticPairingStates[hostID] = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "Automatic local AI pairing could not finish.")
            }
        }
        automaticPairingTasks[hostID] = AutomaticPairingTaskContext(
            routeIdentity: routeIdentity,
            task: task)
    }

    private func automaticPairingRouteIdentity(
        for host: LocalHostAdvertisement
    ) -> String {
        let endpoint = host.localEndpoint.map {
            "\($0.host):\($0.port)"
        } ?? "none"
        return "\(host.senderID ?? "none")|\(host.code)|\(host.localCredentialID ?? "none")|\(host.accountBinding?.rawValue ?? "none")|\(endpoint)"
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

        // Start with every authenticated Mac. Session bindings are intentionally
        // not dictionary keys: two Macs can independently choose the same
        // six-digit code and must remain separate rows.
        var mergedByIdentity: [String: LocalHostAdvertisement] = [:]
        let deterministicCloudHosts = cloudHosts.sorted(
            by: hostMergeInputSortsBefore)
        let authenticatedCloudHosts = deterministicCloudHosts.compactMap { host -> LocalHostAdvertisement? in
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
                hasAuthenticatedCloudMatch: true,
                accountBinding: host.accountBinding)
        }
        for host in authenticatedCloudHosts
            where mergedByIdentity[host.id] == nil {
            mergedByIdentity[host.id] = host
        }

        // Keep malformed/legacy CloudKit rows visible for remote control, but
        // never promote them to authenticated Computer Use rows.
        for host in deterministicCloudHosts
            where host.senderID?.isEmpty != false {
            let unauthenticated = LocalHostAdvertisement(
                hostname: host.hostname,
                code: host.code,
                source: .cloudKit,
                senderID: nil,
                computerUseCapability: host.computerUseCapability,
                hasAuthenticatedCloudMatch: false,
                accountBinding: nil)
            if mergedByIdentity[unauthenticated.id] == nil {
                mergedByIdentity[unauthenticated.id] = unauthenticated
            }
        }

        let cloudByIdentity = Dictionary(
            authenticatedCloudHosts.compactMap { host -> (AuthenticatedIdentity, LocalHostAdvertisement)? in
                guard let identity = authenticatedIdentity(for: host) else {
                    return nil
                }
                return (identity, host)
            },
            uniquingKeysWith: { first, _ in first })
        let cloudByCode = Dictionary(
            grouping: authenticatedCloudHosts,
            by: \.code)
        let legacyLocalCountByCode = Dictionary(
            grouping: localHosts.filter { $0.senderID?.isEmpty != false },
            by: \.code).mapValues(\.count)

        var appliedNearbyIdentities: Set<String> = []
        for localHost in localHosts.sorted(by: hostMergeInputSortsBefore) {
            if let localIdentity = authenticatedIdentity(for: localHost) {
                if let matchingCloud = cloudByIdentity[localIdentity] {
                    // Exact private-CloudKit identity confirms the nearby
                    // advertisement belongs to the reachable environment.
                    // Prefer its monitored capability for prompt progress.
                    let authenticatedNearby = LocalHostAdvertisement(
                        hostname: localHost.hostname,
                        code: localHost.code,
                        source: .localNetwork,
                        senderID: localHost.senderID,
                        computerUseCapability: localHost.computerUseCapability,
                        hasAuthenticatedCloudMatch: true,
                        accountBinding: matchingCloud.accountBinding,
                        localEndpoint: localHost.localEndpoint,
                        localCredentialID: localHost.localCredentialID)
                    if appliedNearbyIdentities.insert(
                        authenticatedNearby.id).inserted {
                        mergedByIdentity[authenticatedNearby.id] =
                            authenticatedNearby
                    }
                } else {
                    // Bonjour is unauthenticated discovery input. An exact
                    // private-CloudKit identity is required before the row is
                    // shown or made actionable.
                    continue
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
                    hasAuthenticatedCloudMatch: true,
                    accountBinding: cloudHost.accountBinding,
                    localEndpoint: localHost.localEndpoint,
                    localCredentialID: localHost.localCredentialID)
                if appliedNearbyIdentities.insert(
                    enrichedLegacy.id).inserted {
                    mergedByIdentity[enrichedLegacy.id] = enrichedLegacy
                }
            } else {
                // Ambiguous or unmatched legacy Bonjour advertisements are
                // hidden until CloudKit identifies one exact same-account Mac.
                continue
            }
        }

        return mergedByIdentity.values.sorted(by: hostSortsBefore)
    }

    /// Total value ordering used before identity de-duplication. Complete local
    /// TLS routes win over incomplete duplicates; all remaining ties include
    /// endpoint and credential data so dictionary/callback order cannot choose
    /// a different route.
    nonisolated static func hostMergeInputSortsBefore(
        _ lhs: LocalHostAdvertisement,
        _ rhs: LocalHostAdvertisement
    ) -> Bool {
        let lhsHasCompleteLocalRoute = lhs.localEndpoint?.isValid == true
            && lhs.localCredentialID.map(
                LocalHostAdvertisement.isValidLocalCredentialID) == true
        let rhsHasCompleteLocalRoute = rhs.localEndpoint?.isValid == true
            && rhs.localCredentialID.map(
                LocalHostAdvertisement.isValidLocalCredentialID) == true
        if lhsHasCompleteLocalRoute != rhsHasCompleteLocalRoute {
            return lhsHasCompleteLocalRoute
        }

        let lhsEndpointHost = lhs.localEndpoint?.host ?? ""
        let rhsEndpointHost = rhs.localEndpoint?.host ?? ""
        let lhsEndpointPort = lhs.localEndpoint?.port ?? 0
        let rhsEndpointPort = rhs.localEndpoint?.port ?? 0
        let comparisons: [(String, String)] = [
            (lhs.hostname, rhs.hostname),
            (lhs.code, rhs.code),
            (lhs.senderID ?? "", rhs.senderID ?? ""),
            (lhs.localCredentialID ?? "", rhs.localCredentialID ?? ""),
            (lhsEndpointHost, rhsEndpointHost),
            (lhs.accountBinding?.rawValue ?? "",
             rhs.accountBinding?.rawValue ?? ""),
            (lhs.source.rawValue, rhs.source.rawValue),
            (lhs.computerUseCapability.state.rawValue,
             rhs.computerUseCapability.state.rawValue),
            (lhs.computerUseCapability.detail,
             rhs.computerUseCapability.detail),
        ]
        for (left, right) in comparisons where left != right {
            return left < right
        }
        if lhsEndpointPort != rhsEndpointPort {
            return lhsEndpointPort < rhsEndpointPort
        }
        if lhs.hasAuthenticatedCloudMatch
            != rhs.hasAuthenticatedCloudMatch {
            return lhs.hasAuthenticatedCloudMatch
                && !rhs.hasAuthenticatedCloudMatch
        }
        return false
    }

    /// Total, locale-stable ordering for rows sourced from dictionaries and
    /// asynchronous discovery callbacks. A folded presentation-name tie is
    /// resolved by the exact name, internal routing binding, then authenticated
    /// SwiftUI identity, so permutations cannot change which row occupies a
    /// position or collapse two case-equivalent Macs.
    nonisolated private static func hostSortsBefore(
        _ lhs: LocalHostAdvertisement,
        _ rhs: LocalHostAdvertisement
    ) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let foldingOptions: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        let lhsFolded = lhs.hostname.folding(
            options: foldingOptions,
            locale: locale)
        let rhsFolded = rhs.hostname.folding(
            options: foldingOptions,
            locale: locale)
        if lhsFolded != rhsFolded {
            return lhsFolded < rhsFolded
        }
        if lhs.hostname != rhs.hostname {
            return lhs.hostname < rhs.hostname
        }
        if lhs.code != rhs.code {
            return lhs.code < rhs.code
        }
        return lhs.id < rhs.id
    }

    private func addNearbyService(_ service: NetService, moreComing: Bool) {
        let name = service.name
        let initialAdvertisement = LocalHostAdvertisement.parse(
            serviceName: name,
            txtRecordData: service.txtRecordData())
        // A DNS-SD browse commonly yields only the PTR/service name first.
        // Retain a bounded hostname-only instance long enough to resolve its
        // TXT/SRV records, but do not publish any row until the TXT routing
        // binding validates. Legacy code-suffixed names may publish at once.
        guard LocalHostAdvertisement.shouldResolveBonjourService(
            serviceName: name,
            txtRecordData: service.txtRecordData()) else {
            return
        }

        nearbyServices.retain(service)
        if let initialAdvertisement {
            _ = nearbyServices.setAdvertisement(
                initialAdvertisement,
                for: service)
        }
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
        let endpoint: LocalComputerUseEndpoint?
        if let hostName = service.hostName,
           !hostName.isEmpty,
           service.port > 0,
           service.port <= Int(UInt16.max) {
            endpoint = LocalComputerUseEndpoint(
                host: hostName,
                port: UInt16(service.port))
        } else {
            endpoint = nil
        }
        guard nearbyServices.contains(service),
              let advertisement = LocalHostAdvertisement.parse(
                serviceName: name,
                txtRecordData: txtRecordData,
                localEndpoint: endpoint) else {
            return
        }
        guard nearbyServices.setAdvertisement(
            advertisement,
            for: service) else { return }
        syncHosts()
    }

    private func stopNearbyResolution() {
        for service in nearbyServices.removeAll() {
            service.stopMonitoring()
            service.stop()
            service.delegate = nil
        }
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
        Task { @MainActor in
            if let retained = self.nearbyServices.remove(service) {
                retained.stopMonitoring()
                retained.stop()
                retained.delegate = nil
            }
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

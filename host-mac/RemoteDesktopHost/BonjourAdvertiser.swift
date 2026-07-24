import Foundation

final class BonjourAdvertiser: NSObject {
    private var service: NetService?
    private var localCredentialID: String?
    private var routingBinding: String?
    private(set) var publishedMetadata: LocalHostBonjourMetadata?

    func publish(
        hostname: String,
        code: String,
        senderID: String,
        computerUseCapability: ComputerUseCapability,
        port: Int32 = 9,
        localCredentialID: String? = nil
    ) {
        stop()
        let advertisedName = LocalHostAdvertisementName.serviceName(hostname: hostname, code: code)
        let service = NetService(domain: "local.",
                                 type: LocalHostAdvertisementName.serviceType,
                                 name: advertisedName,
                                 port: port)
        if let metadata = LocalHostBonjourMetadata(
            senderID: senderID,
            computerUseCapability: computerUseCapability,
            localCredentialID: localCredentialID,
            routingBinding: code
        ), service.setTXTRecord(metadata.txtRecordData()) {
            publishedMetadata = metadata
        }
        self.localCredentialID = localCredentialID
        routingBinding = code
        service.publish()
        self.service = service
    }

    /// Updates AI readiness without withdrawing and republishing the Bonjour
    /// service. Resolved iOS clients monitoring the service receive the new
    /// TXT record while the legacy internal routing binding remains unchanged.
    @discardableResult
    func update(
        senderID: String,
        computerUseCapability: ComputerUseCapability
    ) -> Bool {
        guard let service,
              let metadata = LocalHostBonjourMetadata(
                senderID: senderID,
                computerUseCapability: computerUseCapability,
                localCredentialID: localCredentialID,
                routingBinding: routingBinding) else {
            return false
        }
        if metadata == publishedMetadata {
            return true
        }
        guard service.setTXTRecord(metadata.txtRecordData()) else {
            return false
        }
        publishedMetadata = metadata
        return true
    }

    func stop() {
        service?.stop()
        service = nil
        localCredentialID = nil
        routingBinding = nil
        publishedMetadata = nil
    }
}

enum LocalHostAdvertisementName {
    static let serviceType = "_remotedesktop._tcp."

    static func serviceName(hostname: String, code: String) -> String {
        // Keep the legacy parameter for call-site/source compatibility. The
        // routing value now lives in bounded TXT metadata and is never shown
        // as part of the browser-visible Bonjour instance name.
        _ = code
        return hostname
    }
}

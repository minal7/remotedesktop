import Foundation

final class BonjourAdvertiser: NSObject {
    private var service: NetService?
    private(set) var publishedMetadata: LocalHostBonjourMetadata?

    func publish(
        hostname: String,
        code: String,
        senderID: String,
        computerUseCapability: ComputerUseCapability
    ) {
        stop()
        let advertisedName = LocalHostAdvertisementName.serviceName(hostname: hostname, code: code)
        let service = NetService(domain: "local.",
                                 type: LocalHostAdvertisementName.serviceType,
                                 name: advertisedName,
                                 port: 9)
        if let metadata = LocalHostBonjourMetadata(
            senderID: senderID,
            computerUseCapability: computerUseCapability
        ), service.setTXTRecord(metadata.txtRecordData()) {
            publishedMetadata = metadata
        }
        service.publish()
        self.service = service
    }

    /// Updates AI readiness without withdrawing and republishing the Bonjour
    /// service. Resolved iOS clients monitoring the service receive the new
    /// TXT record while the six-digit legacy service name remains unchanged.
    @discardableResult
    func update(
        senderID: String,
        computerUseCapability: ComputerUseCapability
    ) -> Bool {
        guard let service,
              let metadata = LocalHostBonjourMetadata(
                senderID: senderID,
                computerUseCapability: computerUseCapability) else {
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
        publishedMetadata = nil
    }
}

enum LocalHostAdvertisementName {
    static let serviceType = "_remotedesktop._tcp."

    static func serviceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
    }
}

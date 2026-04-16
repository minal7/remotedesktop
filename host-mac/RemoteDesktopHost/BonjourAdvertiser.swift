import Foundation

final class BonjourAdvertiser: NSObject {
    private var service: NetService?

    func publish(hostname: String, code: String) {
        stop()
        let advertisedName = LocalHostAdvertisementName.serviceName(hostname: hostname, code: code)
        let service = NetService(domain: "local.",
                                 type: LocalHostAdvertisementName.serviceType,
                                 name: advertisedName,
                                 port: 9)
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service = nil
    }
}

enum LocalHostAdvertisementName {
    static let serviceType = "_remotedesktop._tcp."

    static func serviceName(hostname: String, code: String) -> String {
        "\(hostname) [\(code)]"
    }
}

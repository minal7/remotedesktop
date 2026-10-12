import Foundation

enum SafariBridgeXPCClient {
    static func connection(service: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: service, options: [])
        connection.setCodeSigningRequirement(
            SafariBridgeCodeSigning.requirement(for: SafariBridgeXPCNames.helperBundleIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: SafariBridgeBrokerXPC.self)
        connection.resume()
        return connection
    }
}


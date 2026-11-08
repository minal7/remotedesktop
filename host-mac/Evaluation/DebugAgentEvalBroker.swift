#if DEBUG
import Foundation

@MainActor
final class DebugAgentEvalBroker {
    private let server: LocalComputerUseBrokerServer

    init(credential: LocalComputerUseCredential, hostID: String,
         channel: LocalHostComputerUseChannel,
         authorize: @escaping (String) -> Bool,
         revoke: @escaping (String) -> Void) {
        server = LocalComputerUseBrokerServer(credential: credential, hostID: hostID,
            channel: channel, loopbackOnly: true,
            authorizePeer: authorize, revokePeer: revoke)
    }

    func start() async throws -> UInt16 {
        try await server.start()
    }

    func stop() {
        server.stop()
    }
}
#endif

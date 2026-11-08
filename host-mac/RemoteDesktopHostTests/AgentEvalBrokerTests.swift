#if DEBUG
import Network
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalBrokerTests: XCTestCase {
    @MainActor
    func testLoopbackOnlyBindingAcceptsLoopbackAndRejectsOtherPrivatePeers() throws {
        func endpoint(_ address: String) throws -> NWEndpoint {
            .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address(address))), port: .https)
        }

        XCTAssertTrue(LocalComputerUseBrokerServer.isLoopbackEndpoint(try endpoint("127.0.0.1")))
        XCTAssertFalse(LocalComputerUseBrokerServer.isLoopbackEndpoint(try endpoint("192.168.1.4")))
        XCTAssertFalse(LocalComputerUseBrokerServer.isLoopbackEndpoint(try endpoint("10.0.0.2")))
        XCTAssertFalse(LocalComputerUseBrokerServer.isLoopbackEndpoint(try endpoint("8.8.8.8")))
    }
}
#endif

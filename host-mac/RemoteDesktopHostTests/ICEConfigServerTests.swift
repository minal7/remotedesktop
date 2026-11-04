import XCTest
import LiveKitWebRTC
@testable import RemoteDesktopHost

final class ICEConfigServerTests: XCTestCase {
    func testIceServersContainExactlyTheConfiguredSTUNURLs() {
        let urls = ["stun:one.example.invalid", "stun:two.example.invalid"]
        let servers = ICEConfig(stunURLs: urls).iceServers
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].urlStrings, urls)
    }
}

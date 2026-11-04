import Darwin
import XCTest
@testable import RemoteDesktopHost

final class HostPortMapperTests: XCTestCase {
    private final class Token: HostPortMappingToken {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class Mapper: HostPortMapping {
        var tokens: [Token] = []
        var callbacks: [(HostPortMappingResult) -> Void] = []
        func mapUDP(port: UInt16, lanAddress: String, completion: @escaping (HostPortMappingResult) -> Void) -> any HostPortMappingToken {
            let token = Token()
            tokens.append(token)
            callbacks.append(completion)
            return token
        }
    }
    private let candidate = "candidate:abc 1 udp 2122260223 192.168.1.5 4555 typ host generation 0"

    func testMappedCandidateIncludesRelatedAddressAndPriority() throws {
        let parsed = try XCTUnwrap(HostMappingCandidate(sdp: candidate, mid: "video", lineIndex: 2))
        XCTAssertEqual(parsed.mappedSDP(address: "8.8.8.8", port: 7654),
            "candidate:abc 1 udp 1686052606 8.8.8.8 7654 typ srflx raddr 192.168.1.5 rport 4555")
        XCTAssertEqual(parsed.mid, "video")
        XCTAssertEqual(parsed.lineIndex, 2)
        XCTAssertNil(HostMappingCandidate(sdp: candidate.replacingOccurrences(of: " udp ", with: " tcp "), mid: nil, lineIndex: 0))
    }

    func testUnacceptedPeerMakesNoRequest() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, enabled: { true }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "rejected peer")
        DispatchQueue.main.async { XCTAssertTrue(mapper.tokens.isEmpty); done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testClassificationOnlyAllowsAcceptedOrdinaryPeer() {
        XCTAssertFalse(HostPeerSession.allowsPortMapping(for: nil))
        XCTAssertFalse(HostPeerSession.allowsPortMapping(for: .localComputerUseSidecar))
        XCTAssertTrue(HostPeerSession.allowsPortMapping(for: .primaryRemoteControl))
        let mapper = Mapper()
        let sidecar = HostPortMappingSession(mapper: mapper,
            acceptedOrdinaryPeer: HostPeerSession.allowsPortMapping(for: .localComputerUseSidecar),
            enabled: { true }, send: { _, _ in XCTFail() })
        sidecar.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "sidecar")
        DispatchQueue.main.async { XCTAssertTrue(mapper.tokens.isEmpty); done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testICEFailureHookReleasesMappingAndIgnoresLateCallback() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { true }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "failed ICE")
        DispatchQueue.main.async {
            HostPeerSession.handlePortMappingICEState(.failed, session: session)
            DispatchQueue.main.async {
                XCTAssertTrue(mapper.tokens[0].cancelled)
                mapper.callbacks[0](.mapped(address: in_addr_t(0x08080808), port: 7654))
                DispatchQueue.main.async { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 1)
    }

    func testDisabledSettingMakesNoRequest() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { false }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { XCTAssertTrue(mapper.tokens.isEmpty); done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testCloseReleasesMapping() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { true }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "released")
        DispatchQueue.main.async {
            session.close()
            XCTAssertEqual(mapper.tokens.count, 1)
            XCTAssertTrue(mapper.tokens[0].cancelled)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    func testMappedResultSignalsCandidate() {
        let mapper = Mapper()
        let done = expectation(description: "mapped candidate")
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { true }) { candidate, sdp in
            XCTAssertEqual(candidate.mid, "video")
            XCTAssertEqual(sdp, "candidate:abc 1 udp 1686052606 8.8.8.8 7654 typ srflx raddr 192.168.1.5 rport 4555")
            done.fulfill()
        }
        session.gather(sdp: candidate, mid: "video", lineIndex: 0)
        DispatchQueue.main.async { mapper.callbacks[0](.mapped(address: in_addr_t(0x08080808), port: 7654)) }
        wait(for: [done], timeout: 1)
        session.close()
    }

    func testDoubleNATDoesNotSignal() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { true }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "double NAT")
        DispatchQueue.main.async {
            mapper.callbacks[0](.mapped(address: in_addr_t(0x0101a8c0), port: 4000))
            DispatchQueue.main.async { XCTAssertTrue(mapper.tokens[0].cancelled); done.fulfill() }
        }
        wait(for: [done], timeout: 1)
    }

    func testTimeoutDoesNotSignalAndCancels() {
        let mapper = Mapper()
        let session = HostPortMappingSession(mapper: mapper, acceptedOrdinaryPeer: true, enabled: { true }, send: { _, _ in XCTFail() })
        session.gather(sdp: candidate, mid: nil, lineIndex: 0)
        let done = expectation(description: "timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            XCTAssertTrue(mapper.tokens[0].cancelled)
            done.fulfill()
        }
        wait(for: [done], timeout: 4)
    }
}

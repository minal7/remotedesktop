import XCTest
@testable import RemoteDesktop

final class NAT64CandidateSynthesizerTests: XCTestCase {
    func testSynthesisPreservesCandidateFieldsAndLowersPriority() {
        var requested: String?
        let synthesizer = NAT64CandidateSynthesizer { address in
            requested = address
            return "64:ff9b::c000:201"
        }
        let result = synthesizer.candidate(
            from: "candidate:1 1 udp 123 192.0.2.1 4567 typ srflx raddr 10.0.0.1 rport 1234",
            hasIPv4: false, hasIPv6: true)
        XCTAssertEqual(requested, "192.0.2.1")
        XCTAssertEqual(result, "candidate:1 1 udp 122 64:ff9b::c000:201 4567 typ srflx raddr 10.0.0.1 rport 1234")
    }

    func testIPv4OrMissingIPv6DoesNotResolve() {
        let synthesizer = NAT64CandidateSynthesizer { _ in
            XCTFail("Resolver must not run on this path")
            return nil
        }
        let candidate = "candidate:1 1 udp 123 192.0.2.1 4567 typ host"
        XCTAssertNil(synthesizer.candidate(from: candidate, hasIPv4: true, hasIPv6: true))
        XCTAssertNil(synthesizer.candidate(from: candidate, hasIPv4: false, hasIPv6: false))
    }

    func testResolverFailureAndNonIPv4CandidatesProduceNoExtraCandidate() {
        let synthesizer = NAT64CandidateSynthesizer { _ in nil }
        XCTAssertNil(synthesizer.candidate(from: "candidate:1 1 udp 123 192.0.2.1 4567 typ host", hasIPv4: false, hasIPv6: true))
        XCTAssertNil(synthesizer.candidate(from: "candidate:1 1 udp 123 2001:db8::1 4567 typ host", hasIPv4: false, hasIPv6: true))
    }
}

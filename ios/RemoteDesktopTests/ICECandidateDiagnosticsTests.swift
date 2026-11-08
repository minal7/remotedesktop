import XCTest
@testable import RemoteDesktop

final class ICECandidateDiagnosticsTests: XCTestCase {
    func testCandidateSummariesNeverExposeAddressesPortsOrCandidateText() {
        let candidates = [
            "candidate:abc 1 udp 123 192.0.2.47 54321 typ host",
            "candidate:def 1 udp 123 2001:db8::42 54322 typ srflx",
            "candidate:ghi 1 udp 123 device-name.local 54323 typ prflx",
        ]
        var diagnostics = ICECandidateDiagnostics()
        candidates.forEach { diagnostics.record($0) }
        let output = diagnostics.summary
        XCTAssertTrue(output.contains("host_v4=1"))
        XCTAssertTrue(output.contains("srflx_v6=1"))
        XCTAssertTrue(output.contains("prflx_unknown=1"))
        for secret in ["192.0.2.47", "2001:db8::42", "device-name.local", "54321", "54322", "54323", "candidate:"] {
            XCTAssertFalse(output.contains(secret))
        }
        XCTAssertEqual(ICECandidateDiagnostics.kind("192.0.2.47"), "unknown")
        XCTAssertEqual(ICECandidateDiagnostics.transport("54321"), "unknown")
    }

    #if DEBUG
    func testCandidateLifecycleLabelsOnlyExposeTypeAndFamily() {
        let labels = WebRTCTransport.diagnosticCandidateLabels("candidate:private 1 udp 123 192.0.2.47 54321 typ srflx raddr 10.0.0.2 rport 1234")
        XCTAssertEqual(labels.type, "srflx")
        XCTAssertEqual(labels.family, "v4")
        let malformed = WebRTCTransport.diagnosticCandidateLabels("candidate:private secret")
        XCTAssertEqual(malformed.type, "unknown")
        XCTAssertEqual(malformed.family, "unknown")
        let mdns = WebRTCTransport.diagnosticCandidateLabels("candidate:private 1 udp 1 host.local 1234 typ host")
        XCTAssertEqual(mdns.type, "host")
        XCTAssertEqual(mdns.family, "unknown")
    }
    #endif

    func testAttemptEndIsOneShotAndSuppressedAfterVideo() {
        var attempt = ICEDiagnosticAttemptEnd()
        XCTAssertFalse(attempt.end())
        attempt.begin()
        XCTAssertTrue(attempt.end()) // cancel or error before video
        XCTAssertFalse(attempt.end()) // later teardown must not log again
        attempt.begin()
        attempt.didRender()
        XCTAssertFalse(attempt.end())
        XCTAssertFalse(attempt.end())
        attempt.begin()
        XCTAssertTrue(attempt.end()) // a new attempt resets state
    }

    func testGlobalIPv6HostIndicator() {
        var diagnostics = ICECandidateDiagnostics()
        diagnostics.record("candidate:1 1 udp 1 fe80::1 1000 typ host")
        diagnostics.record("candidate:2 1 udp 1 fd00::1 1000 typ host")
        XCTAssertFalse(diagnostics.globalIPv6Host)
        diagnostics.record("candidate:3 1 udp 1 2001:db8::1 1000 typ host")
        XCTAssertFalse(diagnostics.globalIPv6Host)
        diagnostics.record("candidate:4 1 udp 1 2606:4700::1 1000 typ host")
        XCTAssertTrue(diagnostics.globalIPv6Host)
    }
}

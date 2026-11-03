import XCTest
@testable import RemoteDesktopHost

#if DEBUG
final class LatencyLabSenderPolicyTests: XCTestCase {
    private func reports(local: String = "host", remote: String = "host") -> [LatencyStatsReport] {
        [LatencyStatsReport(id: "t", type: "transport", values: ["selectedCandidatePairId": "p"]),
         LatencyStatsReport(id: "p", type: "candidate-pair", values: ["state": "succeeded", "localCandidateId": "l", "remoteCandidateId": "r"]),
         LatencyStatsReport(id: "l", type: "local-candidate", values: ["candidateType": local]),
         LatencyStatsReport(id: "r", type: "remote-candidate", values: ["candidateType": remote])]
    }

    func testOnlyConfirmedHostPairGetsLANFloorAndStart() throws {
        let lan = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        XCTAssertTrue(lan.isLAN)
        XCTAssertEqual(lan.minimumBitrate, 2_500_000)
        XCTAssertEqual(lan.startingBitrate, 10_000_000)
        for remote in ["relay", "srflx", "prflx"] {
            let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: remote)))
            XCTAssertFalse(path.isLAN)
            XCTAssertEqual(path.minimumBitrate, 0, "Leaving LAN must actively remove its old floor")
            XCTAssertEqual(path.startingBitrate, 4_000_000)
            XCTAssertEqual(path.maximumBitrate, 30_000_000)
        }
    }

    func testUnselectedAmbiguousOrIncompletePairsDoNotChangeBandwidth() {
        XCTAssertNil(LatencyLabSenderPolicy.selectedPath(in: Array(reports().dropFirst())))
        XCTAssertNil(LatencyLabSenderPolicy.selectedPath(in: Array(reports().dropLast())))
        XCTAssertNil(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "unknown")))
        var ambiguous = reports()
        ambiguous.append(LatencyStatsReport(id: "other", type: "transport", values: ["selectedCandidatePairId": "other-pair"]))
        XCTAssertNil(LatencyLabSenderPolicy.selectedPath(in: ambiguous))
    }
}
#endif

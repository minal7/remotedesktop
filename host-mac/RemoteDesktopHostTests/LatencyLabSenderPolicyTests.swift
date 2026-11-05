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

    private func stage2Sample(_ time: Double, path: LatencyLabSenderPolicy.Path,
                              captured: UInt64, encoded: Double, rtt: Double? = 0.03,
                              received: Double? = 0, lost: Double? = 0,
                              target: Double? = 1_000_000, outbound: String = "v", remote: String? = "r",
                              fraction: Double? = nil, lossAvailable: Bool = true, lossTime: Double? = nil,
                              responses: Double? = nil) -> LatencyLabSenderPolicy.Stage2Sample {
        let total = (received ?? 0) + (lost ?? 0)
        let ratio = fraction ?? (total > 0 ? (lost ?? 0) / total : 0)
        let ts = lossTime ?? (time + 1) * 1_000_000
        return .init(time: time, path: path, outboundID: outbound, remoteID: remote,
              captureFrames: captured, framesEncoded: encoded, rttSeconds: rtt, rttResponses: responses ?? (time + 1),
              fractionLost: lossAvailable ? ratio : nil, lossTimestampUs: lossAvailable ? ts : nil,
              reportTimestampUs: (time + 1) * 1_000_000, targetBitrate: target)
    }

    func testStage2RequiresExplicitIsolatedOrdinaryLabHost() {
        let args = ["host", "--debug-latency-host"]
        let env = ["LATENCY_LAB": "1", "LATENCY_STAGE2_FLOOR": "1",
                   "REMOTE_DESKTOP_LATENCY_HOST_ID": "8f8f6c31-7bf6-4c51-ae04-5b94b01a59a2"]
        XCTAssertTrue(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: true, ordinaryPeer: true, arguments: args, environment: env))
        XCTAssertFalse(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: false, ordinaryPeer: true, arguments: args, environment: env))
        XCTAssertFalse(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: true, ordinaryPeer: false, arguments: args, environment: env))
        for key in ["LATENCY_LAB", "LATENCY_STAGE2_FLOOR", "REMOTE_DESKTOP_LATENCY_HOST_ID"] {
            var missing = env; missing.removeValue(forKey: key)
            XCTAssertFalse(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: true, ordinaryPeer: true, arguments: args, environment: missing))
        }
        var mixed = env; mixed["REMOTE_DESKTOP_R0_HOST_ID"] = env["REMOTE_DESKTOP_LATENCY_HOST_ID"]
        XCTAssertFalse(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: true, ordinaryPeer: true, arguments: args, environment: mixed))
        XCTAssertFalse(LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: true, ordinaryPeer: true, arguments: ["host"], environment: env))
    }

    func testStage2BaselineAndCandidateFloorsArePathScoped() throws {
        let lan = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        let remote = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        for (candidate, lanFloor, remoteFloor) in [(false, 0, 0), (true, 1_500_000, 1_500_000)] {
            var state = LatencyLabSenderPolicy.Stage2State(candidate: candidate)
            XCTAssertEqual(state.ingest(stage2Sample(0, path: lan, captured: 1, encoded: 1))?.floor, lanFloor)
            XCTAssertEqual(state.ingest(stage2Sample(1, path: remote, captured: 2, encoded: 2))?.floor, remoteFloor)
        }
    }

    func testStage2QualityUsesFreshEvidenceRegardlessOfCandidateType() throws {
        for remote in ["host", "srflx"] {
            let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: remote)))
            var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
            _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.01))
            XCTAssertNil(state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, rtt: 0.01, responses: 1)))
            XCTAssertNil(state.ingest(stage2Sample(2, path: path, captured: 2, encoded: 2, rtt: 0.01, responses: 1)))
            XCTAssertEqual(state.floor, 1_500_000)
            let qualified = state.ingest(stage2Sample(3, path: path, captured: 3, encoded: 3, rtt: 0.01, responses: 2))
            XCTAssertEqual(qualified?.reason, .quality); XCTAssertEqual(qualified?.floor, 8_000_000)
        }
    }

    func testStage2RepeatedRTTDoesNotTriggerCongestion() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0))
        _ = state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, rtt: 0.2))
        for second in 2...5 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), rtt: 0.2, responses: 2)))
        }
        XCTAssertEqual(state.floor, 1_500_000)
        XCTAssertNil(state.ingest(stage2Sample(6, path: path, captured: 6, encoded: 6, rtt: 0.2, responses: 3)))
        XCTAssertNil(state.ingest(stage2Sample(7, path: path, captured: 7, encoded: 7, rtt: 0.2, responses: 4)))
        XCTAssertEqual(state.ingest(stage2Sample(8, path: path, captured: 8, encoded: 8, rtt: 0.2, responses: 5))?.reason, .congestion)
    }

    func testStage2CannotQualifyWithMissingLossOrHighRTT() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0))
        for second in 1...5 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), lossAvailable: false)))
        }
        XCTAssertEqual(state.floor, 1_500_000)
        XCTAssertNil(state.ingest(stage2Sample(6, path: path, captured: 6, encoded: 6, rtt: 0.04)))
        XCTAssertEqual(state.floor, 1_500_000)
    }

    func testStage2QualifiedFloorSurvivesStatsGapWithoutBypassingBackoff() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.01))
        _ = state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, rtt: 0.01))
        XCTAssertEqual(state.ingest(stage2Sample(2, path: path, captured: 2, encoded: 2, rtt: 0.01))?.floor, 8_000_000)
        XCTAssertNil(state.ingest(stage2Sample(7, path: path, captured: 7, encoded: 7, rtt: 0.01)))
        _ = state.ingest(stage2Sample(8, path: path, captured: 8, encoded: 8, rtt: 0.01))
        _ = state.ingest(stage2Sample(9, path: path, captured: 9, encoded: 9, rtt: 0.2))
        _ = state.ingest(stage2Sample(10, path: path, captured: 10, encoded: 10, rtt: 0.2))
        XCTAssertEqual(state.ingest(stage2Sample(11, path: path, captured: 11, encoded: 11, rtt: 0.2))?.floor, 4_000_000)
        for second in 12...21 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), rtt: 0.01)))
        }
        XCTAssertEqual(state.floor, 4_000_000)
        XCTAssertEqual(state.ingest(stage2Sample(22, path: path, captured: 22, encoded: 22, rtt: 0.01))?.floor, 8_000_000)
    }

    func testStage2RecoveryRequiresContinuousFreshRTT() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0))
        for second in 1...3 { _ = state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), rtt: 0.2)) }
        XCTAssertEqual(state.floor, 750_000)
        for second in 4...9 { _ = state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second))) }
        for second in 10...13 { _ = state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), responses: 10)) }
        for second in 14...19 { XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), responses: Double(second - 3)))) }
        XCTAssertEqual(state.floor, 750_000)
    }

    func testStage2CommitsFloorOnlyAfterSDKAcceptsUpdate() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        let failed = state.apply(stage2Sample(0, path: path, captured: 0, encoded: 0)) { _ in false }
        XCTAssertEqual(failed?.applied, false); XCTAssertEqual(state.floor, 0)
        let accepted = state.apply(stage2Sample(1, path: path, captured: 1, encoded: 1)) { _ in true }
        XCTAssertEqual(accepted?.action.reason, .initial); XCTAssertEqual(state.floor, 1_500_000)
        XCTAssertNil(state.apply(stage2Sample(2, path: path, captured: 2, encoded: 2)) { _ in XCTFail("No SDK update expected"); return false })
        XCTAssertEqual(state.floor, 1_500_000)
    }

    func testStage2UnavailableFencesStaleCallbacksEvenWhenSDKRejects() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.apply(stage2Sample(0, path: path, captured: 0, encoded: 0)) { _ in true }
        let rejected = state.unavailable(at: 2, reason: .pathUnavailable) { _ in false }
        XCTAssertEqual(rejected?.applied, false); XCTAssertEqual(state.floor, 1_500_000)
        XCTAssertNil(state.unavailable(at: 1, reason: .codecUnavailable) { _ in XCTFail("Stale callback"); return true })
        let accepted = state.unavailable(at: 3, reason: .codecUnavailable) { $0.floor == 0 }
        XCTAssertEqual(accepted?.action.reason, .codecUnavailable); XCTAssertEqual(accepted?.applied, true)
        XCTAssertEqual(state.floor, 0)
        XCTAssertNil(state.apply(stage2Sample(2.5, path: path, captured: 1, encoded: 1)) { _ in XCTFail("Stale callback"); return true })
    }

    func testStage2LateCallbackCannotRestoreAnOldPath() throws {
        let lan = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        let remote = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: lan, captured: 0, encoded: 0))
        XCTAssertEqual(state.ingest(stage2Sample(2, path: remote, captured: 1, encoded: 1))?.floor, 1_500_000)
        XCTAssertNil(state.ingest(stage2Sample(1, path: lan, captured: 1, encoded: 1)))
        XCTAssertEqual(state.floor, 1_500_000)
    }

    func testStage2BacksOffAfterTwoSecondsAndRecoversOnlyAfterTenHealthySeconds() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.03, received: 0, lost: 0))
        XCTAssertNil(state.ingest(stage2Sample(1, path: path, captured: 60, encoded: 60, received: 97, lost: 3)))
        XCTAssertNil(state.ingest(stage2Sample(2, path: path, captured: 120, encoded: 120, received: 194, lost: 6)))
        let decrease = state.ingest(stage2Sample(3, path: path, captured: 180, encoded: 180, received: 291, lost: 9))
        XCTAssertEqual(decrease?.reason, .congestion); XCTAssertEqual(decrease?.floor, 750_000)
        for second in 4...13 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second * 60),
                encoded: Double(second * 60), received: Double(194 + (second - 2) * 100), lost: 0)))
        }
        let recovery = state.ingest(stage2Sample(14, path: path, captured: 840, encoded: 840, received: 1_394, lost: 0))
        XCTAssertEqual(recovery?.reason, .recovery); XCTAssertEqual(recovery?.floor, 1_500_000)
    }

    func testStage2StrictLossBoundaryAndOutOfOrderSamples() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.03, received: 0, lost: 0))
        XCTAssertNil(state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, received: 98, lost: 2)))
        XCTAssertNil(state.ingest(stage2Sample(2, path: path, captured: 2, encoded: 2, received: 196, lost: 4)))
        XCTAssertEqual(state.floor, 1_500_000, "Exactly two percent is not greater than two percent")
        XCTAssertNil(state.ingest(stage2Sample(1.5, path: path, captured: 0, encoded: 0)))
        XCTAssertNil(state.ingest(stage2Sample(3, path: path, captured: 3, encoded: 3, received: 293, lost: 7)))
        XCTAssertNil(state.ingest(stage2Sample(4, path: path, captured: 4, encoded: 4, received: 390, lost: 10)))
        XCTAssertEqual(state.ingest(stage2Sample(5, path: path, captured: 5, encoded: 5, fraction: 0.03))?.floor, 750_000)
    }

    func testStage2ContinuedCongestionCanReachZeroAndRecoverOneStep() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, received: 0, lost: 0))
        var floors: [Int] = []
        for second in 1...11 {
            if let action = state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second),
                encoded: Double(second), rtt: 0.2, received: Double(second * 100), lost: 0)) {
                floors.append(action.floor)
            }
        }
        XCTAssertEqual(floors, [750_000, 375_000, 187_500, 93_750, 0])
        for second in 12...21 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second),
                encoded: Double(second), received: Double(second * 100), lost: 0)))
        }
        XCTAssertEqual(state.ingest(stage2Sample(22, path: path, captured: 22, encoded: 22, received: 2_200, lost: 0))?.floor, 100_000)
    }

    func testStage2RepeatedRTCPReportIsNotCountedAsFreshLoss() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.03))
        XCTAssertNil(state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, fraction: 0.1)))
        XCTAssertNil(state.ingest(stage2Sample(2, path: path, captured: 2, encoded: 2, fraction: 0.1, lossTime: 2_000_000)))
        XCTAssertEqual(state.floor, 1_500_000)
        XCTAssertNil(state.ingest(stage2Sample(3, path: path, captured: 3, encoded: 3, fraction: 0.1, lossTime: 2_000_000)))
        XCTAssertEqual(state.floor, 1_500_000)
    }

    func testStage2ZeroFloorCanProbeOnFreshRTTWithNoTrafficOrEncoding() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0))
        for second in 1...11 {
            _ = state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: Double(second), rtt: 0.2))
        }
        XCTAssertEqual(state.floor, 0)
        XCTAssertEqual(state.ingest(stage2Sample(12, path: path, captured: 12, encoded: 11, lossAvailable: false))?.reason, .stall)
        for second in 13...21 {
            XCTAssertNil(state.ingest(stage2Sample(Double(second), path: path, captured: UInt64(second), encoded: 11, lossAvailable: false)))
        }
        let probe = state.ingest(stage2Sample(22, path: path, captured: 22, encoded: 11, lossAvailable: false))
        XCTAssertEqual(probe?.reason, .rttProbe); XCTAssertEqual(probe?.floor, 100_000)
    }

    func testStage2StallIsOnePerEpisodeAndNoCaptureDoesNotTrigger() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.03))
        XCTAssertNil(state.ingest(stage2Sample(1, path: path, captured: 0, encoded: 0)))
        let stall = state.ingest(stage2Sample(2, path: path, captured: 60, encoded: 0))
        XCTAssertEqual(stall?.reason, .stall); XCTAssertEqual(stall?.floor, 1_500_000); XCTAssertEqual(stall?.current, 1_500_000)
        XCTAssertNil(state.ingest(stage2Sample(3, path: path, captured: 120, encoded: 0)))
        XCTAssertNil(state.ingest(stage2Sample(4, path: path, captured: 180, encoded: 1)))
        XCTAssertEqual(state.ingest(stage2Sample(5, path: path, captured: 240, encoded: 1))?.reason, .stall)
    }

    func testStage2StallLatchSurvivesMissingStatsUntilEncodingResumes() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports()))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0, rtt: 0.03))
        XCTAssertEqual(state.ingest(stage2Sample(1, path: path, captured: 60, encoded: 0))?.reason, .stall)
        XCTAssertNil(state.ingest(stage2Sample(5, path: path, captured: 120, encoded: 0)))
        XCTAssertNil(state.ingest(stage2Sample(6, path: path, captured: 180, encoded: 0)))
        XCTAssertNil(state.ingest(stage2Sample(7, path: path, captured: 240, encoded: 1)))
        XCTAssertEqual(state.ingest(stage2Sample(8, path: path, captured: 300, encoded: 1))?.reason, .stall)
    }

    func testStage2CounterGapsAndChangesDoNotRestoreRiskyFloor() throws {
        let path = try XCTUnwrap(LatencyLabSenderPolicy.selectedPath(in: reports(remote: "srflx")))
        var state = LatencyLabSenderPolicy.Stage2State(candidate: true)
        _ = state.ingest(stage2Sample(0, path: path, captured: 0, encoded: 0))
        _ = state.ingest(stage2Sample(1, path: path, captured: 1, encoded: 1, rtt: 0.2))
        XCTAssertNil(state.ingest(stage2Sample(2, path: path, captured: 2, encoded: 2, rtt: 0.2)))
        XCTAssertEqual(state.ingest(stage2Sample(3, path: path, captured: 3, encoded: 3, rtt: 0.2))?.floor, 750_000)
        XCTAssertNil(state.ingest(stage2Sample(9, path: path, captured: 3, encoded: 3)))
        XCTAssertEqual(state.floor, 750_000)
        XCTAssertNil(state.ingest(stage2Sample(10, path: path, captured: 4, encoded: 4, outbound: "replacement")))
        XCTAssertEqual(state.floor, 750_000)
        XCTAssertNil(state.ingest(stage2Sample(11, path: path, captured: 0, encoded: 0, outbound: "replacement")))
        XCTAssertEqual(state.floor, 750_000)
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

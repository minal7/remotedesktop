import XCTest
@testable import RemoteDesktopHost

final class LatencyStatsCollectorTests: XCTestCase {
    #if DEBUG
    func testResourceEnvironmentIsLimitedToIsolatedLatencyHost() {
        let id = UUID().uuidString
        let env = ["REMOTE_DESKTOP_LATENCY_HOST_ID": id, "LATENCY_LAB_RESOURCES_ONLY": "1"]
        let selected = ["host", "--debug-latency-host"]
        XCTAssertTrue(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: selected, environment: env))
        XCTAssertFalse(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: ["host"], environment: env))
        XCTAssertFalse(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: selected + ["extra"], environment: env))
        XCTAssertFalse(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: selected, environment: [:]))
        XCTAssertFalse(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: selected,
            environment: env.merging(["REMOTE_DESKTOP_R0_HOST_ID": id]) { _, new in new }))
        XCTAssertFalse(LatencyStatsCollector.isolatedHostResourcesOnly(arguments: selected,
            environment: env.merging(["REMOTE_DESKTOP_LATENCY_HOST_ID": "invalid"]) { _, new in new }))
    }
    #endif

    #if DEBUG
    func testProcessCPUUsesMonotonicDeltasAndResets() {
        var sampler = LatencyProcessCPUSampler()
        XCTAssertNil(sampler.percentage(time: 10, cpu: 2))
        XCTAssertNil(sampler.percentage(time: 10, cpu: 2.5))
        XCTAssertEqual(sampler.percentage(time: 11, cpu: 3.5) ?? -1, 150, accuracy: 0.001)
        XCTAssertNil(sampler.percentage(time: 12, cpu: 1))
        XCTAssertEqual(sampler.percentage(time: 14, cpu: 2) ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(sampler.percentage(time: 13, cpu: 3))
        XCTAssertEqual(sampler.percentage(time: 14, cpu: 3.5) ?? -1, 50, accuracy: 0.001)
    }
    #endif

    func testDeltasRequireSameIDAndResetAfterMissingOrCounterReset() {
        let collector = LatencyStatsCollector(side: "test", enabled: true)
        func sample(_ id: String, _ total: Double, _ count: Int) {
            collector.ingest([LatencyStatsReport(id: id, type: "outbound-rtp", values: ["kind": "video", "totalEncodeTime": total, "framesEncoded": count])], at: 1)
        }
        sample("a", 1, 10)
        XCTAssertNil(collector.snapshot()["encodeMs"])
        sample("a", 1.2, 20)
        XCTAssertEqual(collector.snapshot()["encodeMs"] ?? -1, 20, accuracy: 0.0001)
        sample("b", 2, 30)
        XCTAssertNil(collector.snapshot()["encodeMs"])
        sample("b", 0.1, 1)
        XCTAssertNil(collector.snapshot()["encodeMs"])
        collector.ingest([], at: 2)
        sample("b", 0.2, 2)
        XCTAssertNil(collector.snapshot()["encodeMs"])
    }

    #if DEBUG
    func testTrafficCountersAreNumericAndDeltasFollowReportIdentityAndResets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        func sample(_ id: String, _ value: Int) {
            collector.ingest([LatencyStatsReport(id: id, type: "outbound-rtp", values: [
                "kind": "video", "bytesSent": value, "bytesReceived": value,
                "packetsReceived": value, "retransmittedPacketsSent": value,
                "retransmittedBytesSent": value])], at: Double(value))
        }
        sample("a", 10); sample("a", 15); sample("b", 30); sample("b", 2); sample("b", 4)
        collector.ingest([LatencyStatsReport(id: "b", type: "outbound-rtp", values: [
            "kind": "video", "bytesSent": "do not log this text"])], at: 6)
        collector.flush()
        let data = try Data(contentsOf: url)
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "stats" else { return nil }
            return object
        }
        func report(_ index: Int, _ id: String) throws -> [String: Any] {
            let reports = try XCTUnwrap(rows[index]["reports"] as? [String: [String: Any]])
            return try XCTUnwrap(reports[id])
        }
        let first = try report(0, "a"), second = try report(1, "a")
        let newID = try report(2, "b"), reset = try report(3, "b"), resumed = try report(4, "b")
        for key in ["bytesSent", "bytesReceived", "packetsReceived", "retransmittedPacketsSent", "retransmittedBytesSent"] {
            XCTAssertNil(first[key + "Delta"])
            XCTAssertEqual(second[key + "Delta"] as? Double, 5)
            XCTAssertNil(newID[key + "Delta"])
            XCTAssertNil(reset[key + "Delta"])
            XCTAssertEqual(resumed[key + "Delta"] as? Double, 2)
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("do not log this text"))
    }
    #endif

    func testMultipleRTPReportsUseWeightedDeltas() {
        let collector = LatencyStatsCollector(side: "test", enabled: true)
        func report(_ id: String, _ total: Double, _ count: Int) -> LatencyStatsReport {
            LatencyStatsReport(id: id, type: "outbound-rtp", values: ["kind": "video", "totalEncodeTime": total, "framesEncoded": count])
        }
        collector.ingest([report("a", 0, 0), report("b", 0, 0)], at: 0)
        collector.ingest([report("a", 0.1, 10), report("b", 0.6, 30)], at: 1)
        XCTAssertEqual(collector.snapshot()["encodeMs"] ?? -1, 17.5, accuracy: 0.0001)
        XCTAssertNil(collector.snapshot()["framesEncoded"])
    }

    func testJitterTargetAndActualDelayUseEmittedFrameDeltas() {
        let collector = LatencyStatsCollector(side: "test", enabled: true)
        func sample(_ count: Int, _ target: Double, _ actual: Double) {
            collector.ingest([LatencyStatsReport(id: "in", type: "inbound-rtp", values: [
                "kind": "video", "jitterBufferEmittedCount": count,
                "jitterBufferTargetDelay": target, "jitterBufferDelay": actual])], at: Double(count))
        }
        sample(100, 10, 12)
        XCTAssertNil(collector.snapshot()["jitterBufferTargetMs"])
        sample(120, 10.1, 12.2)
        XCTAssertEqual(collector.snapshot()["jitterBufferTargetMs"] ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(collector.snapshot()["jitterBufferMs"] ?? -1, 10, accuracy: 0.0001)
        sample(1, 0.01, 0.01)
        XCTAssertNil(collector.snapshot()["jitterBufferTargetMs"])
    }

    func testSelectedPairLabelsAndRttFloorNeverExposeAddresses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        func sample(_ rtt: Double) {
            collector.ingest([
                .init(id: "transport", type: "transport", values: ["selectedCandidatePairId": "pair"]),
                .init(id: "pair", type: "candidate-pair", values: ["localCandidateId": "local", "remoteCandidateId": "remote", "currentRoundTripTime": rtt]),
                .init(id: "local", type: "local-candidate", values: ["candidateType": "host", "address": "192.0.2.99", "protocol": "udp"]),
                .init(id: "remote", type: "remote-candidate", values: ["candidateType": "srflx", "ip": "2001:db8::12", "port": 1234])], at: 1)
        }
        sample(0.03); sample(0.02); sample(0.04)
        collector.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("192.0.2.99")); XCTAssertFalse(text.contains("2001:db8::12"))
        XCTAssertFalse(text.contains("\"port\""))
        let rows = try text.split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let stats = try XCTUnwrap(rows.last { $0["type"] as? String == "stats" })
        let values = try XCTUnwrap(stats["values"] as? [String: Any])
        XCTAssertEqual(values["localCandidateType"] as? String, "host")
        XCTAssertEqual(values["localCandidateFamily"] as? String, "v4")
        XCTAssertEqual(values["remoteCandidateType"] as? String, "srflx")
        XCTAssertEqual(values["remoteCandidateFamily"] as? String, "v6")
        XCTAssertEqual(values["candidateProtocol"] as? String, "udp")
        XCTAssertEqual(values["rttFloorMs"] as? Double, 20)
    }

    func testEncodedFramePercentilesAreBoundedAndMarkOverflow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        for size in 1...20 { collector.recordEncodedFrameBytes(size) }
        collector.flushEncodedFrameSizes(at: 1)
        for _ in 0..<513 { collector.recordEncodedFrameBytes(100) }
        collector.flushEncodedFrameSizes(at: 2); collector.flushEncodedFrameSizes(at: 3); collector.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = try text.split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["type"] as? String == "encoded_frame_sizes" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["count"] as? Int, 20); XCTAssertEqual(rows[0]["p50Bytes"] as? Int, 10)
        XCTAssertEqual(rows[0]["p95Bytes"] as? Int, 19); XCTAssertEqual(rows[0]["maxBytes"] as? Int, 20)
        XCTAssertEqual(rows[0]["complete"] as? Bool, true); XCTAssertEqual(rows[1]["complete"] as? Bool, false)
        XCTAssertEqual(rows[1]["count"] as? Int, 512)
    }

    func testOneMinuteOf60FPSFrameRecordsFits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        for i in 0..<3600 {
            let t = 100_000.0 + Double(i) / 60
            collector.trace(["type": "render", "decodeTime": t, "submittedTime": t + 0.002, "presentedTime": t + 0.01])
            collector.trace(["type": "marker", "marker_id": i / 6 + 1, "decodeTime": t, "presentedTime": t + 0.01])
            if i % 30 == 0 { collector.flush() }
        }
        collector.flush()
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 1_000_000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"type\":\"truncated\""))
    }

    func testTraceIsBoundedAndMarksTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        let large = String(repeating: "x", count: 10_000)
        for _ in 0..<110 { collector.trace(["type": "test", "value": large]) }
        collector.flush()
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 1_000_000)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"type\":\"truncated\""))
    }

    #if DEBUG
    func testFailedTraceCannotSilentlyResumeWithMissingRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("trace.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = LatencyStatsCollector(side: "test", enabled: true, traceURL: url)
        collector.trace(["type": "marker", "marker_id": 1])
        collector.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Making the destination writable must not turn a partial session into
        // an apparently complete trace that silently omitted earlier records.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        collector.trace(["type": "marker", "marker_id": 2])
        collector.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    #endif
}

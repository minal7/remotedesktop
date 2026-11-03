import XCTest
@testable import RemoteDesktopHost

final class LatencyStatsCollectorTests: XCTestCase {
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

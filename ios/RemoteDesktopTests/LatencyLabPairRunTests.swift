#if DEBUG
import XCTest
@testable import RemoteDesktop

final class LatencyLabPairRunTests: XCTestCase {
    private func events(_ actions: [LatencyLabPairRun.Action]) -> [[String: Any]] {
        actions.compactMap { if case let .trace(value) = $0 { return value }; return nil }
    }
    private func applied(_ actions: [LatencyLabPairRun.Action]) -> [LatencyLabConfiguration] {
        actions.compactMap { if case let .apply(value) = $0 { return value }; return nil }
    }

    func testRequiresProbeAndExactFixAndKeepsDelayConstant() throws {
        XCTAssertNil(LatencyLabPairRun.make(arguments: ["LatencyLabPairFix", "F1"], maximumDelayMs: 0))
        XCTAssertNil(LatencyLabPairRun.make(arguments: ["LatencyProbe", "LatencyLabPairFix", "f1"], maximumDelayMs: 0))
        XCTAssertNil(LatencyLabPairRun.make(arguments: ["LatencyProbe", "LatencyLabPairFix"], maximumDelayMs: 0))
        XCTAssertNil(LatencyLabPairRun(fix: "F1", maximumDelayMs: 1))
        for fix in ["F1", "F2", "F3", "F4"] {
            var run = try XCTUnwrap(LatencyLabPairRun.make(arguments: ["LatencyProbe", "LatencyLabPairFix", fix], maximumDelayMs: 10))
            let first = run.tick(now: 0, ready: false, currentConfiguration: LatencyLabConfiguration())
            XCTAssertEqual(applied(first).first?.f1MaximumDelayMs, 10)
            XCTAssertEqual(events(first).first?["stage"] as? String, "requested")
            let baseline = run.configuration
            _ = run.tick(now: 1, ready: true, currentConfiguration: baseline)
            _ = run.tick(now: 6, ready: true, currentConfiguration: baseline)
            let next = run.tick(now: 36, ready: true, currentConfiguration: baseline)
            let selected = try XCTUnwrap(applied(next).first)
            XCTAssertEqual(selected.f1MaximumDelayMs, 10)
            XCTAssertEqual([selected.f1Playout, selected.f2Encoder, selected.f3Sender, selected.f4Renderer].filter { $0 }.count, 1)
            switch fix {
            case "F1": XCTAssertTrue(selected.f1Playout)
            case "F2": XCTAssertTrue(selected.f2Encoder)
            case "F3": XCTAssertTrue(selected.f3Sender)
            case "F4": XCTAssertTrue(selected.f4Renderer)
            default: XCTFail("Unexpected fix")
            }
        }
    }

    func testDelayedReadinessNeedsFiveContinuousSecondsAndLateEndUsesExactBoundary() throws {
        var run = try XCTUnwrap(LatencyLabPairRun(fix: "F1", maximumDelayMs: 0))
        _ = run.tick(now: 0, ready: false, currentConfiguration: .init())
        let baseline = run.configuration
        XCTAssertTrue(events(run.tick(now: 10, ready: true, currentConfiguration: baseline)).isEmpty)
        XCTAssertTrue(events(run.tick(now: 14, ready: false, currentConfiguration: baseline)).isEmpty)
        XCTAssertTrue(events(run.tick(now: 15, ready: true, currentConfiguration: baseline)).isEmpty)
        XCTAssertTrue(events(run.tick(now: 19.9, ready: true, currentConfiguration: baseline)).isEmpty)
        let begin = events(run.tick(now: 20, ready: true, currentConfiguration: baseline))
        XCTAssertEqual(begin.first?["stage"] as? String, "begin")
        XCTAssertEqual(begin.first?["time"] as? Double, 20)
        // An interruption during measurement is retained as part of the run.
        XCTAssertTrue(run.tick(now: 40, ready: false, currentConfiguration: baseline).isEmpty)
        let ended = run.tick(now: 53, ready: false, currentConfiguration: baseline)
        XCTAssertEqual(events(ended).map { $0["stage"] as? String }, ["end", "requested"])
        XCTAssertEqual(events(ended).first?["time"] as? Double, 50)
        XCTAssertEqual(events(ended).last?["time"] as? Double, 53)
        XCTAssertTrue(try XCTUnwrap(applied(ended).first).f1Playout)
    }

    func testUnsupportedBAbortsAfterWaitingAndRestoresBaseline() throws {
        var run = try XCTUnwrap(LatencyLabPairRun(fix: "F3", maximumDelayMs: 20))
        _ = run.tick(now: 0, ready: false, currentConfiguration: .init())
        let baseline = run.configuration
        _ = run.tick(now: 1, ready: true, currentConfiguration: baseline)
        _ = run.tick(now: 6, ready: true, currentConfiguration: baseline)
        _ = run.tick(now: 36, ready: true, currentConfiguration: baseline)
        let b = run.configuration
        XCTAssertTrue(b.f3Sender)
        XCTAssertTrue(run.tick(now: 80.9, ready: false, currentConfiguration: b).isEmpty)
        let aborted = run.tick(now: 81, ready: false, currentConfiguration: b)
        XCTAssertEqual(events(aborted).first?["stage"] as? String, "aborted")
        XCTAssertEqual(events(aborted).first?["reason"] as? String, "readiness_timeout")
        XCTAssertEqual(applied(aborted), [baseline]); XCTAssertTrue(run.finished)
        XCTAssertTrue(run.tick(now: 82, ready: true, currentConfiguration: baseline).isEmpty)
    }

    func testFourInterleavedPairsUseFullWindowsAndRestoreBaseline() throws {
        var run = try XCTUnwrap(LatencyLabPairRun(fix: "F4", maximumDelayMs: 10))
        var actions = run.tick(now: 0, ready: false, currentConfiguration: .init())
        var allEvents = events(actions), now = 0.0
        for trial in 1...8 {
            let config = run.configuration
            XCTAssertEqual(config.f4Renderer, trial.isMultiple(of: 2))
            XCTAssertEqual(config.f1MaximumDelayMs, 10)
            _ = run.tick(now: now + 1, ready: true, currentConfiguration: config)
            actions = run.tick(now: now + 6, ready: true, currentConfiguration: config)
            allEvents += events(actions)
            actions = run.tick(now: now + 36, ready: false, currentConfiguration: config)
            allEvents += events(actions)
            now += 36
        }
        let starts = allEvents.filter { $0["stage"] as? String == "begin" }
        let ends = allEvents.filter { $0["stage"] as? String == "end" }
        XCTAssertEqual(starts.count, 8); XCTAssertEqual(ends.count, 8)
        for index in 0..<8 {
            XCTAssertEqual(ends[index]["time"] as! Double - (starts[index]["time"] as! Double), 30)
            XCTAssertEqual(starts[index]["trial"] as? Int, index + 1)
            XCTAssertEqual(starts[index]["pair"] as? Int, index / 2 + 1)
            XCTAssertEqual(starts[index]["arm"] as? String, index.isMultiple(of: 2) ? "A" : "B")
            XCTAssertEqual(starts[index]["run"] as? String, starts[0]["run"] as? String)
        }
        XCTAssertEqual(events(actions).last?["stage"] as? String, "complete")
        let restored = try XCTUnwrap(applied(actions).last)
        XCTAssertFalse(restored.f4Renderer); XCTAssertEqual(restored.f1MaximumDelayMs, 10)
        XCTAssertTrue(run.finished)
    }

    func testExternalConfigurationChangeAbortsDuringWaitAndMeasurement() throws {
        for measuring in [false, true] {
            var run = try XCTUnwrap(LatencyLabPairRun(fix: "F2", maximumDelayMs: 0))
            _ = run.tick(now: 0, ready: false, currentConfiguration: .init())
            let baseline = run.configuration
            if measuring {
                _ = run.tick(now: 1, ready: true, currentConfiguration: baseline)
                _ = run.tick(now: 6, ready: true, currentConfiguration: baseline)
            }
            var changed = baseline; changed.f3Sender = true
            let actions = run.tick(now: measuring ? 7 : 1, ready: true, currentConfiguration: changed)
            XCTAssertEqual(events(actions).first?["stage"] as? String, "aborted")
            XCTAssertEqual(events(actions).first?["reason"] as? String, "configuration_changed")
            XCTAssertEqual(applied(actions), [baseline]); XCTAssertTrue(run.finished)
        }
    }
}
#endif

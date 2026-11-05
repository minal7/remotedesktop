import Foundation
import AppKit

@main struct DeviceMarkerProbeTests {
    static func main() {
        let cases: [(TimeInterval, Bool)] = [(-1, false), (0, false), (1.999, false),
                                             (2, true), (3.999, true), (4, false),
                                             (5.999, false), (6, true), (600, false)]
        for (elapsed, expected) in cases {
            precondition(LargeChangeCadence.isPhoto(elapsed: elapsed) == expected,
                         "Unexpected scene at \(elapsed) seconds")
        }
        let parseCases: [(String?, LargeChangeCadence.Interval?)] = [
            (nil, .stress), ("2", .stress), ("2.0", .stress), ("8", .recovery), ("8.0", .recovery),
            ("", nil), ("0", nil), ("3", nil), ("-2", nil), ("nan", nil), ("inf", nil), ("-inf", nil), ("2.1", nil)]
        for (raw, expected) in parseCases {
            precondition(LargeChangeCadence.Interval.parse(raw) == expected, "Invalid scene interval validation")
        }
        let recovery: [(TimeInterval, Bool)] = [(-1, false), (0, false), (7.999, false),
                                               (8, true), (15.999, true), (16, false), (24, true)]
        for (elapsed, expected) in recovery {
            precondition(LargeChangeCadence.isPhoto(elapsed: elapsed, interval: .recovery) == expected,
                         "Unexpected 8-second scene at \(elapsed)")
        }
        precondition(!LargeChangeCadence.isPhoto(elapsed: .nan, interval: .recovery))
        precondition(LargeChangeCadence.Interval.stress.role == "stress" && LargeChangeCadence.Interval.recovery.role == "recovery")
        let steps: [(TimeInterval, Int)] = [(-1, 0), (0, 0), (1.0 / 120, 0),
                                             (1.0 / 60, 1), (0.5, 30), (1, 60), (601, 36_000)]
        for (elapsed, expected) in steps {
            precondition(FixtureAnimationCadence.step(elapsed: elapsed) == expected,
                         "Unexpected animation step at \(elapsed)")
        }
        let frame = FixtureAnimationCadence.frame(in: NSRect(x: 0, y: 0, width: 1000, height: 800))
        precondition(frame.minY >= 0 && frame.maxY < 370, "Animation must not cover marker cells")
        let range = FixtureAnimationCadence.requestedRange
        precondition(range.minimum == 60 && range.maximum == 60 && range.preferred == 60,
                     "Animation requests a fixed 60 Hz display link")
        precondition(FixtureAnimationCadence.validTarget(10, after: nil))
        precondition(FixtureAnimationCadence.validTarget(11, after: 10))
        precondition(!FixtureAnimationCadence.validTarget(10, after: 10))
        precondition(!FixtureAnimationCadence.validTarget(9, after: 10))
        precondition(!FixtureAnimationCadence.validTarget(.nan, after: nil))
        precondition(!FixtureAnimationCadence.validTarget(0, after: nil))
        for index in 0...120 {
            let anchor = 10_000.0
            let target = anchor + Double(index) / 60 - (index == 0 ? 0 : 0.000_01)
            precondition(FixtureAnimationCadence.displayStep(target: target, anchor: anchor) == index,
                         "Display target must advance one 60 Hz step")
        }
        let roi = Pattern.textReferenceROI
        precondition(roi == NSRect(x: 64, y: 144, width: 256, height: 64))
        precondition(!roi.intersects(frame), "Text reference must not include animation")
        precondition(roi.maxY < 370, "Text reference must not include marker")
        print("170 fixture checks passed")
    }
}

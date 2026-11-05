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
        print("145 cadence, marker-separation and display-link checks passed")
    }
}

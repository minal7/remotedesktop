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
        print("17 cadence and marker-separation checks passed")
    }
}

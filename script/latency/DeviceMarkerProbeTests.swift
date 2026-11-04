import Foundation

@main struct DeviceMarkerProbeTests {
    static func main() {
        let cases: [(TimeInterval, Bool)] = [(-1, false), (0, false), (1.999, false),
                                             (2, true), (3.999, true), (4, false),
                                             (5.999, false), (6, true), (600, false)]
        for (elapsed, expected) in cases {
            precondition(LargeChangeCadence.isPhoto(elapsed: elapsed) == expected,
                         "Unexpected scene at \(elapsed) seconds")
        }
        print("9 cadence checks passed")
    }
}

#if DEBUG
import SwiftUI
import UIKit

struct LocalUnixClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            VStack(spacing: 20) {
                Text("Local device clock · \(UIDevice.current.model)")
                    .font(.headline)
                Text(String(format: "%lld.%03lld", milliseconds / 1_000, milliseconds % 1_000))
                    .font(.system(size: 80, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.25)
                    .accessibilityLabel("Unix timestamp in seconds")
                Text("Unix timestamp · seconds.milliseconds · UTC")
                    .font(.subheadline)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .foregroundStyle(.white)
            .ignoresSafeArea()
        }
    }
}
#endif

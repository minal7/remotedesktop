import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: SessionModel

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                PairingView()
            case .connecting, .connected:
                SessionView()
            case .ended(let reason):
                EndedView(reason: reason)
            }
        }
        .animation(.smooth(duration: 0.25), value: session.state)
    }
}

private struct EndedView: View {
    @EnvironmentObject private var session: SessionModel
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Session ended").font(.title2.weight(.semibold))
            Text(reason).foregroundStyle(.secondary)
            Button("Pair again") { session.reset() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var session: SessionModel
    @StateObject private var discovery = LocalHostDiscovery()
    @State private var code: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "display")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Pair with your computer")
                    .font(.title.weight(.semibold))
                Text("Enter the 6-digit code shown on your computer.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(8)
                .focused($focused)
                .onChange(of: code) { _, v in
                    code = String(v.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

            if let err = session.error {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                if case .connecting = session.state {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect").font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count != 6 || session.state == .connecting)

            if !discovery.hosts.isEmpty {
                nearbyHosts
            }

            Spacer()

            Text("Your computer stays private — traffic flows directly between your devices, end-to-end encrypted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            discovery.start()
        }
        .onDisappear { discovery.stop() }
    }

    private func submit() {
        focused = false
        session.connect(code: code)
    }

    private var nearbyHosts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nearby on this Wi-Fi")
                .font(.headline)

            ForEach(discovery.hosts) { host in
                Button {
                    focused = false
                    code = host.code
                    session.connect(code: host.code)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.hostname)
                                .font(.body.weight(.semibold))
                            Text("Tap to connect without entering the code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "wifi")
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(session.state == .connecting)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

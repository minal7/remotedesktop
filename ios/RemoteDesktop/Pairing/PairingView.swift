import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var session: SessionModel
    @StateObject private var discovery = LocalHostDiscovery()
    @State private var code: String = ""
    @State private var showManualPairing = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                Image(systemName: "display")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Remote Desktop")
                        .font(.title.weight(.semibold))
                    Text("Select a computer to connect, or enter a pairing code manually.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let err = session.error {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                // MARK: – Available Devices

                availableDevices

                // MARK: – Manual Pairing (collapsed by default)

                manualPairingSection

                Spacer(minLength: 12)

                Text("Your computer stays private — traffic flows directly between your devices, end-to-end encrypted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            discovery.start()
        }
        .onDisappear { discovery.stop() }
    }

    // MARK: - Available Devices

    private var availableDevices: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Available Devices")
                    .font(.headline)
                Spacer()
                if !discovery.hosts.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if discovery.hosts.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Searching for computers…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else {
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
                                Text("Tap to connect")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "desktopcomputer")
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
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    // MARK: - Manual Pairing

    private var manualPairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showManualPairing.toggle()
                    if showManualPairing {
                        focused = true
                    } else {
                        focused = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showManualPairing ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Connect with Code")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showManualPairing {
                VStack(spacing: 16) {
                    Text("Enter the 6-digit code shown on your computer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 36, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .tracking(8)
                        .focused($focused)
                        .onChange(of: code) { _, v in
                            code = String(v.filter(\.isNumber).prefix(6))
                            if code.count == 6 { submit() }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

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
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func submit() {
        focused = false
        session.connect(code: code)
    }
}

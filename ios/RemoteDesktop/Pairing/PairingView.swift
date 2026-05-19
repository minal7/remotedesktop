import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var session: SessionModel
    @StateObject private var discovery = LocalHostDiscovery()
    @State private var code: String = ""
    @State private var showCodeEntry = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let err = session.error {
                    errorBanner(err)
                }

                availableDevices
                manualPairing
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
                .ignoresSafeArea()
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to host")
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("Choose an available device first. If your host is not listed, enter its pairing code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.red.opacity(0.16), lineWidth: 1)
            }
    }

    private var availableDevices: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Available devices",
                count: discovery.hosts.isEmpty ? nil : discovery.hosts.count,
                isLoading: discovery.hosts.isEmpty
            )

            if discovery.hosts.isEmpty {
                emptyDevicesState
            } else {
                VStack(spacing: 10) {
                    ForEach(discovery.hosts) { host in
                        hostButton(host)
                    }
                }
            }
        }
        .padding(18)
        .sectionSurface()
    }

    private var emptyDevicesState: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Searching for hosts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Open the host app, or use a pairing code below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var manualPairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "Pair with code")

            Button {
                toggleCodeEntry()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "number.square")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())

                    Text("Enter code")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(showCodeEntry ? .degrees(180) : .zero)
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(session.state == .connecting)

            if showCodeEntry {
                codeEntryForm
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
        .padding(18)
        .sectionSurface()
        .animation(.smooth(duration: 0.28), value: showCodeEntry)
    }

    private var codeEntryForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(8)
                .focused($focused)
                .onChange(of: code) { _, value in
                    code = String(value.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityLabel("Pairing code")

            Button(action: submit) {
                HStack {
                    Spacer()
                    if case .connecting = session.state {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Connect")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count != 6 || session.state == .connecting)
        }
        .padding(16)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func sectionHeader(title: String, count: Int? = nil, isLoading: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
            }
        }
    }

    private func hostButton(_ host: LocalHostAdvertisement) -> some View {
        Button {
            focused = false
            code = host.code
            session.connect(code: host.code)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.hostname)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Ready to connect")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(session.state == .connecting)
    }

    private func toggleCodeEntry() {
        withAnimation(.smooth(duration: 0.28)) {
            showCodeEntry.toggle()
        }

        if showCodeEntry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                focused = true
            }
        } else {
            focused = false
        }
    }

    private func submit() {
        guard code.count == 6 else { return }
        focused = false
        session.connect(code: code)
    }
}

private extension View {
    func sectionSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

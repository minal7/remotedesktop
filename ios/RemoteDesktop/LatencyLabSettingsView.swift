#if DEBUG
import SwiftUI

struct LatencyLabSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = LatencyLabConfiguration.current

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Reduce buffering (F1)", isOn: $settings.f1Playout)
                if settings.f1Playout {
                    Picker("Maximum playout delay", selection: $settings.f1MaximumDelayMs) {
                        ForEach([0, 10, 20], id: \.self) { value in
                            Text("\(value) ms").tag(value)
                        }
                    }
                }
                Toggle("Lower encoding delay (F2)", isOn: $settings.f2Encoder)
                Toggle("Faster LAN sending (F3)", isOn: $settings.f3Sender)
                Toggle("Metal rendering at 120 Hz (F4)", isOn: $settings.f4Renderer)
                Section {
                    Button("Apply to this session") {
                        LatencyLabConfiguration.setRuntime(settings)
                        dismiss()
                    }
                    Button("Reset all experiments") { settings = LatencyLabConfiguration() }
                } footer: {
                    Text("Applying changes briefly reconnects video. Each selection is recorded with the measurements.")
                }
            }
            .navigationTitle("Latency lab")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
#endif

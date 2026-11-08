import SwiftUI

struct ComputerUseTaskMemoryControls: View {
    @ObservedObject var model: ComputerUseSessionModel

    var body: some View {
        Menu {
            Toggle("Don't use memory", isOn: $model.noMemoryForNextTask)
                .disabled(!model.canChangeTaskMemoryOptions)
                .accessibilityIdentifier("computer-use-no-memory")
            Toggle("Incognito task", isOn: $model.incognitoForNextTask)
                .disabled(!model.canChangeTaskMemoryOptions)
                .accessibilityIdentifier("computer-use-incognito-task")
            Text("These choices apply to new tasks.")
        } label: {
            Label("Memory options", systemImage: "brain")
                .font(.caption.weight(.medium))
        }
        .accessibilityIdentifier("computer-use-task-memory-options")
    }
}

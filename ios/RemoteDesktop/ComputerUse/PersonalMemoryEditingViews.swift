import SwiftUI

struct PersonalMemoryRememberSheet: View {
    @ObservedObject var model: PersonalMemoryViewModel
    let initialText: String?
    let initialKind: LocalMemoryRPCCommand.RememberKind?
    let onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LocalMemoryRPCCommand.RememberKind
    @State private var text: String

    init(model: PersonalMemoryViewModel, initialText: String? = nil,
         initialKind: LocalMemoryRPCCommand.RememberKind? = nil, onSaved: (() -> Void)? = nil) {
        self.model = model
        self.initialText = initialText
        self.initialKind = initialKind
        self.onSaved = onSaved
        _text = State(initialValue: initialText ?? "")
        _kind = State(initialValue: initialKind ?? .fact)
    }

    private var textIsValid: Bool {
        let command = LocalMemoryRPCCommand(rememberKind: kind, text: text,
                                            commandID: UUID().uuidString.lowercased())
        return (try? command.validate()) != nil
    }

    private var locksDraft: Bool {
        model.rememberState == .saving || model.rememberState == .unknown
            || model.rememberState == .saved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Save a memory") {
                    Picker("Type", selection: $kind) {
                        Text("Preference").tag(LocalMemoryRPCCommand.RememberKind.profile)
                        Text("Fact").tag(LocalMemoryRPCCommand.RememberKind.fact)
                    }
                    .disabled(locksDraft)
                    .accessibilityIdentifier("personal-memory-remember-kind")
                    TextEditor(text: $text)
                        .frame(minHeight: 130)
                        .disabled(locksDraft)
                        .accessibilityLabel("Memory text")
                        .accessibilityIdentifier("personal-memory-remember-text")
                    Text("Save an owner preference or ordinary fact. Do not save passwords or other secrets here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rememberStatus
                rememberAction
            }
            .navigationTitle("Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.rememberState == .idle ? "Cancel" : "Close") { dismiss() }
                        .disabled(model.rememberState == .saving)
                        .accessibilityIdentifier(model.rememberState == .idle
                            ? "personal-memory-remember-cancel" : "personal-memory-remember-close")
                }
            }
        }
        .accessibilityIdentifier("personal-memory-remember-sheet")
        .interactiveDismissDisabled(model.rememberState == .saving)
        .onDisappear {
            if model.rememberState == .saved {
                model.finishRememberPresentation()
                onSaved?()
            } else {
                model.cancelRememberComposition()
            }
        }
    }

    @ViewBuilder
    private var rememberStatus: some View {
        switch model.rememberState {
        case .idle:
            EmptyView()
        case .saving:
            Section {
                ProgressView("Saving memory…")
                Text("Closing does not undo a save the Mac has already received.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("personal-memory-remember-pending")
        case .unknown:
            Section {
                Text("The Mac did not confirm whether this memory was saved. Retry sends the same request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Closing does not undo a save the Mac has already received.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("personal-memory-remember-unknown")
        case .saved:
            Section {
                Label("Memory saved", systemImage: "checkmark.circle")
                Button("Done") {
                    dismiss()
                }
                    .accessibilityIdentifier("personal-memory-remember-done")
            }
            .accessibilityIdentifier("personal-memory-remember-result")
        case .rejected:
            Section {
                Text("The Mac did not accept this memory. You can revise it and try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("personal-memory-remember-rejected")
        }
    }

    @ViewBuilder
    private var rememberAction: some View {
        if model.rememberState == .unknown {
            Section {
                Button("Retry save") { _ = model.retryRemember() }
                    .accessibilityIdentifier("personal-memory-remember-retry")
            }
        } else if model.rememberState != .saved {
            Section {
                Button(model.rememberState == .saving ? "Saving…" : "Save memory") {
                    _ = model.saveRemember(kind: kind, text: text)
                }
                .disabled(!textIsValid || locksDraft)
                .accessibilityIdentifier("personal-memory-remember-save")
            }
        }
    }
}

struct PersonalMemoryComposerRememberSheet: View {
    @ObservedObject var model: PersonalMemoryViewModel
    let originalText: String
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingRememberForm = false

    var body: some View {
        Group {
            if showingRememberForm {
                PersonalMemoryRememberSheet(model: model, initialText: formText,
                                            initialKind: formKind, onSaved: onSaved)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if case .error(let message) = model.state {
                            ContentUnavailableView("Memory couldn’t be loaded", systemImage: "brain.head.profile",
                                                   description: Text(message))
                            Button("Try again") { model.open() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView("Opening memory…")
                        }
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    .padding()
                    .navigationTitle("Remember")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onAppear(perform: openOrContinue)
        .onChange(of: model.state) { _, _ in openOrContinue() }
        .onChange(of: model.rememberState) { _, _ in openOrContinue() }
        .onDisappear {
            if !showingRememberForm, model.state == .loading { model.close() }
        }
    }

    private func openOrContinue() {
        guard !showingRememberForm else { return }
        switch model.rememberState {
        case .saving, .unknown, .saved:
            showingRememberForm = true
            return
        case .idle, .rejected:
            break
        }
        if model.state == .unavailable {
            model.open()
            return
        }
        guard model.state == .ready || isError(model.state) else { return }
        if model.beginRememberComposition() { showingRememberForm = true }
    }

    private func isError(_ state: PersonalMemoryViewModel.State) -> Bool {
        if case .error = state { return true }
        return false
    }

    private var formText: String {
        if model.rememberState == .saving || model.rememberState == .unknown {
            return model.pendingRemember?.text ?? originalText
        }
        return originalText
    }

    private var formKind: LocalMemoryRPCCommand.RememberKind? {
        if model.rememberState == .saving || model.rememberState == .unknown {
            return model.pendingRemember?.kind
        }
        return nil
    }
}

struct PersonalMemoryEditorSheet: View {
    @ObservedObject var model: PersonalMemoryViewModel
    @Environment(\.dismiss) private var dismiss
    let record: LocalMemoryRPCRecord
    @State private var text: String
    @State private var expectedReceipt: PersonalMemoryViewModel.MutationReceipt?
    @State private var confirmsDelete = false

    private let maximumBytes = LocalComputerUseRPCLimits.maximumMemoryTextBytes

    init(model: PersonalMemoryViewModel, record: LocalMemoryRPCRecord) {
        self.model = model
        self.record = record
        _text = State(initialValue: model.recoverableDraft(for: record) ?? record.text)
    }

    private var textIsValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= maximumBytes
            && text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    || $0 == "\n" || $0 == "\r" || $0 == "\t"
            }
    }

    private var isSubmitting: Bool {
        if case .loading = model.state { return true }
        return false
    }

    private var hasUnknownDraft: Bool {
        guard model.recoverableDraft(for: record) == text else { return false }
        if case .error = model.state { return true }
        return false
    }

    private var byteCountLabel: String {
        let count = text.utf8.count
        return "\(count) of \(maximumBytes) bytes"
    }

    var body: some View {
        NavigationStack {
            editorForm
            .navigationTitle(record.kind == .profile ? "Edit profile" : "Edit fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("personal-memory-editor-cancel")
                }
            }
            .confirmationDialog("Delete this memory?", isPresented: $confirmsDelete,
                                titleVisibility: .visible) {
                Button("Delete memory", role: .destructive) {
                    if let requestID = model.delete(record: record) {
                        expectedReceipt = PersonalMemoryViewModel.MutationReceipt(
                            kind: .delete, recordID: record.recordID, requestID: requestID)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the selected saved memory.")
            }
        }
        .onChange(of: model.mutationReceipt) { _, receipt in
            guard let receipt, let expectedReceipt,
                  receipt.matches(kind: expectedReceipt.kind,
                                  recordID: expectedReceipt.recordID,
                                  requestID: expectedReceipt.requestID) else { return }
            dismiss()
        }
        .accessibilityIdentifier("personal-memory-editor-sheet")
    }

    private var editorForm: some View {
        Form {
            textSection
            statusSection
            actionsSection
        }
    }

    private var textSection: some View {
        Section("Memory") {
            TextEditor(text: $text)
                .frame(minHeight: 150)
                .disabled(isSubmitting)
                .accessibilityLabel("Memory text")
                .accessibilityIdentifier("personal-memory-editor-text")
            HStack {
                Text(byteCountLabel)
                Spacer()
                if !textIsValid { Text("Enter valid memory text") }
            }
            .font(.caption)
            .foregroundStyle(textIsValid ? Color.secondary : Color.red)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if hasUnknownDraft {
            Section {
                Text("The change may have completed. Retry this exact text to continue safely.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("personal-memory-unknown-outcome")
        } else if case .error(let message) = model.state {
            Section {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("personal-memory-edit-error")
        }
    }

    private var actionsSection: some View {
        Section {
            Button(hasUnknownDraft ? "Retry save" : "Save changes") {
                if let requestID = model.edit(record: record, text: text) {
                    expectedReceipt = PersonalMemoryViewModel.MutationReceipt(
                        kind: .edit, recordID: record.recordID, requestID: requestID)
                }
            }
            .disabled(!textIsValid || isSubmitting)
            .accessibilityIdentifier("personal-memory-save")

            Button("Delete memory", role: .destructive) {
                confirmsDelete = true
            }
            .disabled(isSubmitting)
            .accessibilityIdentifier("personal-memory-delete")
        }
    }
}

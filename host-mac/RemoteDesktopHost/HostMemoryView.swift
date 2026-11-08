import AppKit
import SwiftUI

/// Bounded owner-memory browser for the settings window. It only talks to the
/// already-bound local memory controller and keeps editor text in view state.
struct HostMemoryView: View {
    @ObservedObject var model: PersonalMemoryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFocused: Bool

    @State private var isVisible = false
    @State private var query = ""
    @State private var selection: String?
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editingRecord: LocalMemoryRPCRecord?
    @State private var expectedReceipt: PersonalMemoryViewModel.MutationReceipt?
    @State private var confirmsDelete = false
    @State private var forgetConfirmationToken: UUID?
    @State private var confirmsForget = false

    private let maximumTextBytes = LocalComputerUseRPCLimits.maximumMemoryTextBytes

    private var selectedRecord: LocalMemoryRPCRecord? {
        guard let selection else { return nil }
        return model.records.first(where: { $0.recordID == selection })
    }

    private var editorValid: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editText.utf8.count <= maximumTextBytes
            && editText.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    || $0 == "\n" || $0 == "\r" || $0 == "\t"
            }
    }

    private var isSubmitting: Bool {
        if case .loading = model.state { return true }
        return false
    }

    private var recoverableDraft: String? {
        guard let record = selectedRecord else { return nil }
        return model.recoverableDraft(for: record)
    }

    private var showingUnknownOutcome: Bool {
        guard let recoverableDraft, recoverableDraft == editText else { return false }
        if case .error = model.state { return true }
        return false
    }

    private var canBeginForget: Bool {
        !isEditing && !isSubmitting && expectedReceipt == nil
            && model.forgetCommandID == nil && forgetConfirmationToken == nil
            && model.generationReference != nil
            && (model.state == .ready || isErrorState)
    }

    private var isErrorState: Bool {
        if case .error = model.state { return true }
        return false
    }

    var body: some View {
        Group {
            if model.forgetCommandID != nil {
                forgetStatus
            } else {
                memoryBrowser
            }
        }
        .accessibilityIdentifier("host-memory-view")
        .confirmationDialog("Forget everything?", isPresented: $confirmsForget,
                            titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { confirmForget() }
                .accessibilityIdentifier("host-memory-forget-confirm")
            Button("Cancel", role: .cancel) { cancelForgetConfirmation() }
                .accessibilityIdentifier("host-memory-forget-cancel")
        } message: {
            Text("This permanently removes saved memories stored by Remote Desktop. Exported copies and data in other apps aren’t removed.")
        }
        .onAppear {
            isVisible = true
            if model.forgetCommandID == nil {
                query = model.query
                model.open(query: query)
            }
        }
        .onDisappear {
            isVisible = false
            cancelForgetConfirmation()
            model.close()
            query = ""
            confirmsDelete = false
            clearEditor()
            selection = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearForBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
                clearForBackground()
            }
        .onChange(of: confirmsForget) { wasVisible, isVisible in
            if wasVisible && !isVisible { cancelForgetConfirmation() }
        }
        .onChange(of: model.state) { _, state in
            if state == .unavailable {
                cancelForgetConfirmation()
                query = ""
                confirmsDelete = false
                selection = nil
                clearEditor()
            }
        }
        .onChange(of: model.records.map(\.recordID)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
                if !isSubmitting { clearEditor() }
            }
        }
        .onChange(of: model.mutationReceipt) { _, receipt in
            guard let receipt, let expectedReceipt,
                  receipt.matches(kind: expectedReceipt.kind,
                                  recordID: expectedReceipt.recordID,
                                  requestID: expectedReceipt.requestID) else { return }
            if receipt.kind == .delete { selection = nil }
            clearEditor()
        }
    }

    private var memoryBrowser: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(minWidth: 155, idealWidth: 190, maxWidth: 225)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
    }

    @ViewBuilder
    private var forgetStatus: some View {
        VStack(spacing: 12) {
            if model.forgetInProgress {
                ProgressView("Forgetting everything…")
                    .accessibilityIdentifier("host-memory-forget-progress")
            } else if model.forgetCompleted {
                Label("Memory forgotten", systemImage: "checkmark.shield")
                    .font(.headline)
                    .accessibilityIdentifier("host-memory-forget-completed")
            } else {
                Label("Forget outcome uncertain", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Retry the same confirmed request to finish safely.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry Forget") {
                    _ = model.retryForget()
                }
                .disabled(model.forgetInProgress || model.forgetCompleted)
                .accessibilityIdentifier("host-memory-forget-retry")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("host-memory-forget-status")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search saved memories", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(runSearch)
                .disabled(isEditing || isSubmitting)
                .accessibilityLabel("Search saved memories")
                .accessibilityIdentifier("host-memory-search")
            Button(action: runSearch) {
                Text("Search")
            }
            .disabled(isEditing || isSubmitting)
            .accessibilityIdentifier("host-memory-search-submit")
            if !query.isEmpty {
                Button {
                    query = ""
                    runSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(isEditing || isSubmitting)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        Group {
            if model.records.isEmpty {
                sidebarEmptyState
            } else {
                List(selection: $selection) {
                    ForEach(model.records, id: \.recordID) { record in
                        MemorySidebarRow(record: record)
                            .tag(record.recordID)
                            .accessibilityIdentifier("host-memory-item-\(record.recordID)")
                    }
                }
                .listStyle(.sidebar)
                .disabled(isEditing || isSubmitting)
                .accessibilityLabel("Saved memories")
                .accessibilityIdentifier("host-memory-list")
            }
        }
    }

    @ViewBuilder
    private var sidebarEmptyState: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("host-memory-loading")
        case .error(let message):
            VStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { model.reload() }
                    .controlSize(.small)
                    .accessibilityIdentifier("host-memory-retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
        case .ready:
            ContentUnavailableView(
                query.isEmpty ? "No memories" : "No matches",
                systemImage: query.isEmpty ? "brain.head.profile" : "magnifyingglass")
                .accessibilityIdentifier("host-memory-empty")
        case .unavailable:
            VStack(spacing: 8) {
                ContentUnavailableView("Memory is closed", systemImage: "lock")
                Button("Reload memories") { model.open(query: query) }
                    .controlSize(.small)
                    .accessibilityIdentifier("host-memory-reload")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let record = selectedRecord {
            recordDetail(record)
        } else {
            ContentUnavailableView("Select a memory", systemImage: "text.book.closed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("host-memory-no-selection")
        }
    }

    private func recordDetail(_ record: LocalMemoryRPCRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(record.kind == .profile ? "Profile" : "Fact",
                          systemImage: record.kind == .profile ? "person.text.rectangle" : "quote.bubble")
                        .font(.headline)
                    Spacer()
                    Text(record.active ? "Active" : "Superseded")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(record.active ? Color.green : Color.secondary)
                }

                if isEditing, let editingRecord {
                    editor(editingRecord)
                } else {
                    Text(record.text)
                        .font(.body)
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host-memory-detail-text")
                }

                Divider()
                metadata(record)

                if let message = model.errorMessage, case .error = model.state {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host-memory-error")
                }

                if !isEditing {
                    HStack {
                        Button("Edit") { beginEditing(record) }
                            .accessibilityIdentifier("host-memory-edit")
                        Spacer()
                        Button("Delete…", role: .destructive) { confirmsDelete = true }
                            .accessibilityIdentifier("host-memory-delete")
                    }
                    .disabled(isSubmitting)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete this memory?", isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button("Delete memory", role: .destructive) { delete(record) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes only the selected saved memory.")
        }
        .accessibilityIdentifier("host-memory-detail")
    }

    private func editor(_ record: LocalMemoryRPCRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editText)
                .font(.body)
                .frame(minHeight: 115)
                .disabled(isSubmitting)
                .accessibilityLabel("Memory text")
                .accessibilityIdentifier("host-memory-editor")
            HStack {
                Text(byteCountLabel)
                Spacer()
                if !editorValid { Text("Enter valid text") }
            }
            .font(.caption)
            .foregroundStyle(editorValid ? Color.secondary : Color.red)

            if showingUnknownOutcome {
                Text("The change may have completed. Retry this exact text to continue safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("host-memory-unknown-outcome")
            }

            HStack {
                Button(showingUnknownOutcome ? "Retry save" : "Save") {
                    save(record)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!editorValid || isSubmitting)
                .accessibilityIdentifier("host-memory-save")
                Button("Cancel") { clearEditor() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("host-memory-edit-cancel")
            }
        }
    }

    private func metadata(_ record: LocalMemoryRPCRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(record.source == .ownerMessage ? "From your message" : "Confirmed by you",
                  systemImage: record.source == .ownerMessage ? "bubble.left" : "checkmark.seal")
            Label(Date(timeIntervalSince1970: Double(record.observedAtMilliseconds) / 1_000)
                .formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("host-memory-provenance")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if case .loading = model.state {
                ProgressView().controlSize(.small)
                Text("Loading memories…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.nextRecordID != nil {
                Button("Load more") { model.loadMore() }
                    .controlSize(.small)
                    .disabled(isEditing || isSubmitting)
                    .accessibilityIdentifier("host-memory-load-more")
            } else if model.state == .ready, !model.records.isEmpty {
                Text("All matching memories shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("host-memory-complete")
            }
            Spacer()
            if model.state != .loading, case .error = model.state {
                Button("Retry") { model.reload() }
                    .controlSize(.small)
                    .disabled(isEditing || isSubmitting)
                    .accessibilityIdentifier("host-memory-retry-footer")
            }
            if let message = model.errorMessage, model.state == .unavailable {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("Forget everything…", role: .destructive) {
                beginForgetConfirmation()
            }
            .disabled(!canBeginForget)
            .accessibilityIdentifier("host-memory-forget")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(.bar)
    }

    private func runSearch() {
        guard !isEditing, !isSubmitting else { return }
        model.open(query: query)
        selection = nil
        clearEditor()
    }

    private func beginEditing(_ record: LocalMemoryRPCRecord) {
        editText = model.recoverableDraft(for: record) ?? record.text
        editingRecord = record
        expectedReceipt = nil
        isEditing = true
    }

    private func save(_ record: LocalMemoryRPCRecord) {
        guard selection == record.recordID,
              let current = selectedRecord,
              current.revision == record.revision else { return }
        guard let requestID = model.edit(record: record, text: editText) else { return }
        expectedReceipt = PersonalMemoryViewModel.MutationReceipt(
            kind: .edit, recordID: record.recordID, requestID: requestID)
    }

    private func delete(_ record: LocalMemoryRPCRecord) {
        guard selectedRecord?.recordID == record.recordID,
              selectedRecord?.revision == record.revision else { return }
        guard let requestID = model.delete(record: record) else { return }
        expectedReceipt = PersonalMemoryViewModel.MutationReceipt(
            kind: .delete, recordID: record.recordID, requestID: requestID)
    }

    private func clearEditor() {
        isEditing = false
        editText = ""
        editingRecord = nil
        expectedReceipt = nil
    }

    private var byteCountLabel: String {
        "\(editText.utf8.count) / \(maximumTextBytes) bytes"
    }

    private func clearForBackground() {
        guard isVisible else { return }
        cancelForgetConfirmation()
        model.close()
        query = ""
        selection = nil
        confirmsDelete = false
        clearEditor()
    }

    private func beginForgetConfirmation() {
        guard canBeginForget, let token = model.beginForgetConfirmation() else { return }
        forgetConfirmationToken = token
        confirmsForget = true
    }

    private func cancelForgetConfirmation() {
        confirmsForget = false
        guard let token = forgetConfirmationToken else { return }
        forgetConfirmationToken = nil
        model.cancelForgetConfirmation(token)
    }

    private func confirmForget() {
        guard let token = forgetConfirmationToken else { return }
        // Clear every view-local copy before the model dispatches the destructive command.
        forgetConfirmationToken = nil
        confirmsForget = false
        query = ""
        selection = nil
        confirmsDelete = false
        clearEditor()
        if model.confirmForget(token) == nil {
            model.cancelForgetConfirmation(token)
        }
    }
}

private struct MemorySidebarRow: View {
    let record: LocalMemoryRPCRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: record.kind == .profile ? "person.text.rectangle" : "quote.bubble")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.kind == .profile ? "Profile" : "Fact")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(record.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

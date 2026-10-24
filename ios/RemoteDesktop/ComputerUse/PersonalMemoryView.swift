import SwiftUI

struct PersonalMemoryButton: View {
    @ObservedObject var model: ComputerUseSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: MemorySheet?
    @State private var activeMemory: PersonalMemoryViewModel?

    private struct MemorySheet: Identifiable {
        let model: PersonalMemoryViewModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
    }

    var body: some View {
        Group {
            if let memory = model.ownerMemory {
                Button {
                    guard model.isConnected, scenePhase == .active, !isApprovalRequired else { return }
                    memory.open()
                    activeMemory = memory
                    sheet = MemorySheet(model: memory)
                } label: {
                    Label("Memory", systemImage: "brain.head.profile")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Memory")
                .accessibilityHint("View memories saved for this owner")
                .accessibilityIdentifier("computer-use-memory-button")
                .disabled(!model.isConnected || scenePhase != .active || isApprovalRequired)
                .sheet(item: $sheet, onDismiss: closePresentedMemory) { destination in
                    PersonalMemoryView(model: destination.model)
                }
            }
        }
        .onChange(of: ownerMemoryIdentity) { oldValue, newValue in
            if oldValue != newValue { closePresentedMemory() }
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            closePresentedMemory()
        }
        .onChange(of: model.state) { _, state in
            if case .approvalRequired = state { closePresentedMemory() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { closePresentedMemory() }
        }
    }

    private var ownerMemoryIdentity: ObjectIdentifier? {
        model.ownerMemory.map { ObjectIdentifier($0) }
    }

    private var isApprovalRequired: Bool {
        if case .approvalRequired = model.state { return true }
        return false
    }

    private func closePresentedMemory() {
        activeMemory?.close()
        activeMemory = nil
        sheet = nil
    }
}

struct PersonalMemoryView: View {
    @ObservedObject var model: PersonalMemoryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var presentedSheet: MemorySheetDestination?
    @State private var showingWhy = false
    @State private var showingForgetConfirmation = false
    @State private var forgetDialogToken: UUID?
    @State private var showingFreshMemoryConfirmation = false
    @State private var freshMemoryDialogToken: UUID?

    private struct EditDestination: Identifiable {
        let record: LocalMemoryRPCRecord
        var id: String { "\(record.recordID):\(record.revision)" }
    }

    private enum MemorySheetDestination: Identifiable {
        case edit(EditDestination)
        case remember(UUID)
        var id: String {
            switch self {
            case .edit(let destination): "edit:\(destination.id)"
            case .remember(let token): "remember:\(token.uuidString)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.forgetCommandID != nil {
                    forgetStatusContent
                } else {
                    searchBar
                    recordsContent
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingWhy = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Why these memories?")
                    .accessibilityHint("Explain the source and date labels")
                    .accessibilityIdentifier("personal-memory-why")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        guard model.beginRememberComposition() else { return }
                        presentedSheet = .remember(UUID())
                    } label: {
                        Label("Add memory", systemImage: "plus")
                    }
                    .disabled(!model.canBeginRemember || model.forgetCommandID != nil)
                    .accessibilityIdentifier("personal-memory-add")
                    Button("Forget", role: .destructive) {
                        beginForgetConfirmation()
                    }
                    .disabled(model.forgetCommandID != nil || model.forgetInProgress
                              || model.generationReference == nil)
                    .accessibilityIdentifier("personal-memory-forget")
                    Button("Close") { closeView() }
                        .accessibilityIdentifier("personal-memory-close")
                }
            }
            .sheet(item: $presentedSheet, onDismiss: model.cancelRememberComposition) { destination in
                switch destination {
                case .edit(let editor):
                    PersonalMemoryEditorSheet(model: model, record: editor.record)
                case .remember:
                    PersonalMemoryRememberSheet(model: model)
                }
            }
            .alert("About these memories", isPresented: $showingWhy) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("These are the profile details and facts saved for this owner. The source and date show where each memory came from.")
            }
            .confirmationDialog("Forget everything?", isPresented: $showingForgetConfirmation,
                                titleVisibility: .visible) {
                Button("Forget Everything", role: .destructive) {
                    confirmForget()
                }
                .accessibilityIdentifier("personal-memory-forget-confirm")
                Button("Cancel", role: .cancel) {
                    cancelForgetConfirmation()
                }
                .accessibilityIdentifier("personal-memory-forget-cancel")
            } message: {
                Text("This erases this app’s saved memories and stops any current task. You can’t undo this. It does not erase exported copies or content stored in other apps.")
                    .accessibilityIdentifier("personal-memory-forget-warning")
            }
            .accessibilityIdentifier("personal-memory-forget-confirmation")
            .confirmationDialog("Start fresh Memory?", isPresented: $showingFreshMemoryConfirmation,
                                titleVisibility: .visible) {
                Button("Start Fresh Memory", role: .destructive) {
                    confirmFreshMemory()
                }
                .accessibilityIdentifier("personal-memory-fresh-confirm")
                Button("Cancel", role: .cancel) {
                    cancelFreshMemoryConfirmation()
                }
                .accessibilityIdentifier("personal-memory-fresh-cancel")
            } message: {
                Text("This creates an empty memory store for this owner. Reconnect before viewing the new memory.")
            }
            .accessibilityIdentifier("personal-memory-fresh-confirmation")
        }
        .accessibilityIdentifier("personal-memory-screen")
        .onAppear { searchText = model.query }
        .onChange(of: model.query) { _, query in searchText = query }
        .onChange(of: showingForgetConfirmation) { _, isPresented in
            if !isPresented { cancelForgetConfirmation() }
        }
        .onChange(of: showingFreshMemoryConfirmation) { _, isPresented in
            if !isPresented { cancelFreshMemoryConfirmation() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { closeLocalPresentationState() }
        }
        .onDisappear { closeLocalPresentationState() }
    }

    private var forgetStatusContent: some View {
        Group {
            if model.initializationCompleted {
                ContentUnavailableView("Fresh memory is ready", systemImage: "sparkles",
                    description: Text("Reconnect to view the new, empty memory store."))
                    .accessibilityIdentifier("personal-memory-fresh-ready")
            } else if model.initializationCommandID != nil {
                if model.initializationInProgress {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting fresh memory…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("personal-memory-fresh-pending")
                } else {
                    ContentUnavailableView {
                        Label("Fresh memory status unknown", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The Mac did not confirm whether fresh memory was created.")
                    } actions: {
                        Button("Retry Start Fresh Memory", role: .destructive) {
                            _ = model.retryFreshMemoryInitialization()
                        }
                        .disabled(!model.canRetryFreshMemoryInitialization)
                        .accessibilityIdentifier("personal-memory-fresh-retry")
                    }
                    .accessibilityIdentifier("personal-memory-fresh-unknown")
                }
            } else if model.forgetInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Forgetting saved memories…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("personal-memory-forget-pending")
            } else if model.forgetCompleted {
                VStack(spacing: 16) {
                    ContentUnavailableView("Memory forgotten", systemImage: "checkmark.shield",
                        description: Text("This app’s saved memories have been erased."))
                    if model.canBeginFreshMemory {
                        Button("Start Fresh Memory", role: .destructive) {
                            beginFreshMemoryConfirmation()
                        }
                        .accessibilityIdentifier("personal-memory-start-fresh")
                    }
                }
                .accessibilityIdentifier("personal-memory-forget-result")
            } else {
                ContentUnavailableView {
                    Label("Forget status unknown", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The Mac did not confirm whether erasure finished. Your saved memories may already be gone.")
                } actions: {
                    Button("Retry Forget", role: .destructive) {
                        _ = model.retryForget()
                    }
                    .accessibilityIdentifier("personal-memory-forget-retry")
                }
                .accessibilityIdentifier("personal-memory-forget-unknown")
            }
        }
    }

    private func beginForgetConfirmation() {
        guard model.forgetCommandID == nil else { return }
        presentedSheet = nil
        guard let token = model.beginForgetConfirmation() else { return }
        forgetDialogToken = token
        showingForgetConfirmation = true
    }

    private func confirmForget() {
        guard let token = forgetDialogToken else { return }
        searchText = ""
        presentedSheet = nil
        forgetDialogToken = nil
        showingForgetConfirmation = false
        _ = model.confirmForget(token)
    }

    private func beginFreshMemoryConfirmation() {
        guard model.forgetCompleted, let token = model.beginFreshMemoryConfirmation() else { return }
        freshMemoryDialogToken = token
        showingFreshMemoryConfirmation = true
    }

    private func confirmFreshMemory() {
        guard let token = freshMemoryDialogToken else { return }
        freshMemoryDialogToken = nil
        showingFreshMemoryConfirmation = false
        _ = model.confirmFreshMemory(token)
    }

    private func cancelFreshMemoryConfirmation() {
        if let token = freshMemoryDialogToken {
            model.cancelFreshMemoryConfirmation(token)
            freshMemoryDialogToken = nil
        }
        showingFreshMemoryConfirmation = false
    }

    private func cancelForgetConfirmation() {
        if let token = forgetDialogToken {
            model.cancelForgetConfirmation(token)
            forgetDialogToken = nil
        }
        showingForgetConfirmation = false
    }

    private func closeLocalPresentationState() {
        cancelForgetConfirmation()
        cancelFreshMemoryConfirmation()
        searchText = ""
        presentedSheet = nil
        model.cancelRememberComposition()
    }

    private func closeView() {
        closeLocalPresentationState()
        dismiss()
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search memories", text: $searchText)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.open(query: searchText) }
                .accessibilityIdentifier("personal-memory-search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    model.open()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var recordsContent: some View {
        if model.records.isEmpty {
            emptyOrProgress
        } else {
            List {
                ForEach(model.records, id: \.recordID) { record in
                    PersonalMemoryRow(record: record) {
                        presentedSheet = .edit(EditDestination(record: record))
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                }

                if case .loading = model.state {
                    HStack { Spacer(); ProgressView("Loading memories"); Spacer() }
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("personal-memory-loading-more")
                } else if case .error(let message) = model.state {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { model.reload() }
                            .accessibilityIdentifier("personal-memory-retry")
                    }
                    .padding(.vertical, 8)
                }

                if model.nextRecordID != nil, model.state != .loading {
                    Button {
                        model.loadMore()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Load more", systemImage: "arrow.down.circle")
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("personal-memory-load-more")
                } else if model.nextRecordID == nil, model.state == .ready {
                    Text("All matching memories are shown")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("personal-memory-complete")
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("personal-memory-record-list")
        }
    }

    @ViewBuilder
    private var emptyOrProgress: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading memories")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("personal-memory-loading")
        case .error(let message):
            ContentUnavailableView {
                Label("Memories unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { model.reload() }
                    .accessibilityIdentifier("personal-memory-retry")
            }
        case .ready:
            ContentUnavailableView(
                searchText.isEmpty ? "No saved memories" : "No matching memories",
                systemImage: searchText.isEmpty ? "brain.head.profile" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Profile details and facts saved for this owner will appear here."
                    : "Try a different search."))
                .accessibilityIdentifier("personal-memory-empty")
        case .unavailable:
            ContentUnavailableView("Memory unavailable", systemImage: "lock")
        }
    }
}

private struct PersonalMemoryRow: View {
    let record: LocalMemoryRPCRecord
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.kind == .profile ? "Profile" : "Fact")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(record.active ? "Active" : "Superseded")
                    .font(.caption)
                    .foregroundStyle(record.active ? Color.green : Color.secondary)
            }
            Text(record.text)
                .font(.body)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                Text(record.source == .ownerMessage ? "From your message" : "Confirmed by you")
                Text("·")
                Text(Date(timeIntervalSince1970: Double(record.observedAtMilliseconds) / 1_000)
                    .formatted(date: .abbreviated, time: .omitted))
                Spacer(minLength: 4)
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .padding(5)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit memory")
                .accessibilityIdentifier("personal-memory-edit-\(record.recordID)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personal-memory-row-\(record.recordID)")
    }
}

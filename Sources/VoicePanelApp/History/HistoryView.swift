import AppKit
import SwiftUI
import VoicePanelCore

struct HistoryView: View {
    @ObservedObject var history: HistoryModel
    @State private var selectedID: UUID?
    @State private var copiedID: UUID?
    @State private var pendingDeletion: TranscriptHistoryRecord?
    @State private var asksToResetEncryptedHistory = false

    private var selectedRecord: TranscriptHistoryRecord? {
        guard let selectedID else { return history.filteredRecords.first }
        return history.records.first(where: { $0.id == selectedID })
    }

    var body: some View {
        Group {
            if !history.storageEnabled {
                ContentUnavailableView(
                    "History Is Off",
                    systemImage: "clock.badge.xmark",
                    description: Text("Enable encrypted history in Settings to save future transcripts.")
                )
            } else if history.isUnlocked {
                historyContent
            } else {
                lockedContent
            }
        }
        .frame(
            minWidth: 720,
            maxWidth: .infinity,
            minHeight: 470,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history-window.root")
        .onChange(of: history.isUnlocked) { _, isUnlocked in
            if isUnlocked, selectedID == nil {
                selectedID = history.filteredRecords.first?.id
            }
        }
        .onChange(of: history.filteredRecords.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = ids.first
            } else if self.selectedID == nil {
                self.selectedID = ids.first
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { record in
            Button("Delete Transcript", role: .destructive) {
                history.delete(id: record.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("This removes the saved text from encrypted history. This action cannot be undone.")
        }
        .alert(
            "Start a New Encrypted History?",
            isPresented: $asksToResetEncryptedHistory
        ) {
            Button("Archive Current History and Create New Key", role: .destructive) {
                history.resetEncryptedHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Saved transcripts will be removed from the current history and kept in an encrypted recovery archive. VoicePanel will create a new Keychain key without requiring access to the previous key."
            )
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if history.records.isEmpty, history.searchText.isEmpty {
            emptyHistoryContent
        } else {
            VStack(spacing: 0) {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 350)
                } detail: {
                    detail
                        .frame(minWidth: 400)
                }
                .toolbar(removing: .sidebarToggle)
                Divider()
                footer
            }
            .onAppear {
                if selectedID == nil {
                    selectedID = history.filteredRecords.first?.id
                }
            }
        }
    }

    private var emptyHistoryContent: some View {
        VStack(spacing: 0) {
            Spacer()
            ContentUnavailableView {
                Label("No Transcripts Yet", systemImage: "quote.bubble")
            } description: {
                Text(
                    "Completed recordings will appear here for the retention period selected in Settings."
                )
                .frame(maxWidth: 430)
            } actions: {
                if history.canRecoverPreviousHistory {
                    recoverPreviousHistoryButton
                }
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                Text("History is encrypted and protected by macOS authentication")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 18)
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                Text("Encrypted History Locked")
                    .font(.system(size: 28, weight: .bold))

                Text("Use Touch ID or your Mac login password to view saved transcripts.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await history.unlock() }
                } label: {
                    if history.isUnlocking {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Unlocking…")
                        }
                    } else {
                        Text("Unlock History")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(history.isUnlocking)

                if let error = history.lastError, !history.isUnlocking {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                }

                if history.canResetEncryptedHistory {
                    Button("Clear Current History and Start Over", role: .destructive) {
                        asksToResetEncryptedHistory = true
                    }
                    .buttonStyle(.bordered)
                }

                if history.canRecoverPreviousHistory {
                    recoverPreviousHistoryButton
                }
            }
            .padding(.top, 22)
            .frame(maxWidth: 480)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HistorySearchField(
                text: $history.searchText,
                prompt: "Search Transcripts"
            )
            .frame(height: 24)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            List(history.filteredRecords, selection: $selectedID) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.medium))
                        Spacer()
                        if record.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(record.text)
                        .lineLimit(2)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .tag(record.id)
            }
            .listStyle(.sidebar)
            .overlay {
                if history.filteredRecords.isEmpty {
                    ContentUnavailableView.search(text: history.searchText)
                }
            }
        }
        .navigationTitle("History")
    }

    @ViewBuilder
    private var detail: some View {
        if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcript")
                            .font(.headline.weight(.semibold))
                        Text(record.createdAt.formatted(date: .complete, time: .shortened))
                            .font(.callout)
                        Text("\(record.languageIdentifier) · \(record.engineName) · \(formatDuration(record.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        history.togglePinned(id: record.id)
                    } label: {
                        Label(
                            record.isPinned ? "Unpin" : "Pin",
                            systemImage: record.isPinned ? "pin.slash" : "pin"
                        )
                    }
                }
                .padding(18)

                Divider()

                ScrollView {
                    Text(record.text)
                        .textSelection(.enabled)
                        .font(.system(size: 16, design: .rounded))
                        .accessibilityIdentifier("history-window.transcript")
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }

                Divider()

                HStack {
                    Button("Delete", role: .destructive) { pendingDeletion = record }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.text, forType: .string)
                        copiedID = record.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            if copiedID == record.id { copiedID = nil }
                        }
                    } label: {
                        Label(
                            copiedID == record.id ? "Copied" : "Copy",
                            systemImage: copiedID == record.id ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Select a Transcript",
                systemImage: "sidebar.left",
                description: Text("Choose an item in the History sidebar to read or copy it.")
            )
        }
    }

    private var footer: some View {
        HStack {
            if let error = history.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text("\(history.records.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("history-window.count")
            }
            Spacer()
            if history.canRecoverPreviousHistory {
                recoverPreviousHistoryButton
            }
            Button("Clear Unpinned") { history.clearUnpinned() }
                .disabled(history.records.allSatisfy { $0.isPinned })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var recoverPreviousHistoryButton: some View {
        Button {
            Task { await history.recoverPreviousHistory() }
        } label: {
            if history.isRecoveringHistory {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Recovering…")
                }
            } else {
                Label("Recover Previous History…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
        }
        .disabled(history.isRecoveringHistory)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = prompt
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = prompt
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }
    }
}

#if DEBUG
    @MainActor
    private struct HistoryPreviewHost: View {
        private let environment: VoicePanelPreviewEnvironment

        init(unlocked: Bool = true, storageEnabled: Bool = true) {
            let environment = VoicePanelPreviewEnvironment(historyUnlocked: unlocked)
            if !storageEnabled {
                environment.settings.historyStorageMode = .none
            }
            self.environment = environment
        }

        var body: some View {
            HistoryView(history: environment.history)
                .frame(width: 900, height: 570)
        }
    }

    private struct HistorySearchFieldPreviewHost: View {
        @State private var text = "benchmark"

        var body: some View {
            HistorySearchField(text: $text, prompt: "Search Transcripts")
                .frame(width: 300, height: 28)
                .padding()
        }
    }

    #Preview("History · Unlocked") {
        HistoryPreviewHost()
    }

    #Preview("History · Locked") {
        HistoryPreviewHost(unlocked: false)
    }

    #Preview("History · Disabled") {
        HistoryPreviewHost(storageEnabled: false)
    }

    #Preview("History Search Field") {
        HistorySearchFieldPreviewHost()
    }
#endif

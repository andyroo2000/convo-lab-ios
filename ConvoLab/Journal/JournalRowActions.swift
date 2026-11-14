import SwiftUI

struct JournalRowActions: View {
    let row: JournalDraft
    let store: JournalStore
    @State private var renaming: JournalDraft?
    @State private var showingDelete = false
    @State private var isDeleting = false

    var body: some View {
        Menu {
            Button("Rename", systemImage: "pencil") { renaming = snapshot() }
            Button("Delete", systemImage: "trash", role: .destructive) { showingDelete = true }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isDeleting || store.busyEntryIDs.contains(row.id))
        .accessibilityLabel("Actions for \(row.title ?? "Untitled entry")")
        .accessibilityIdentifier("JournalRowActions-\(row.id)")
        .outsideDismissibleSheet(item: $renaming) { JournalRenameSheet(entry: $0, store: store) }
        .alert("Delete this entry?", isPresented: $showingDelete) {
            Button("Delete entry", role: .destructive) { Task { await deleteEntry() } }
            Button("Keep entry", role: .cancel) {}
        } message: {
            Text("“\(row.title ?? "Untitled entry")” will be permanently deleted. You can’t undo this action.")
        }
    }

    private func snapshot() -> JournalDraft {
        var draft = row
        draft.expectedVersion = max(row.expectedVersion, store.entries.first(where: { $0.id == row.id })?.version ?? 0)
        return draft
    }

    private func deleteEntry() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do { try await store.delete(id: row.id) }
        catch { store.errorMessage = error.localizedDescription }
    }
}

import SwiftUI

struct JournalRowActions: View {
    let row: JournalDraft
    let store: JournalStore
    var onDeleted: () -> Void = {}
    var onRenamed: () -> Void = {}
    @State private var renaming: JournalDraft?
    @State private var deleting: JournalDraft?

    var body: some View {
        JournalOptionsMenu {
            JournalOptionButton(title: "Rename", icon: "pencil") { renaming = snapshot() }
            JournalOptionButton(title: "Delete", icon: "trash", destructive: true) { deleting = snapshot() }
        }
        .disabled(store.busyEntryIDs.contains(row.id))
        .accessibilityLabel("Actions for \(row.title ?? "Untitled entry")")
        .accessibilityIdentifier("JournalRowActions-\(row.id)")
        .outsideDismissibleSheet(item: $renaming) { JournalRenameSheet(entry: $0, store: store, onSaved: onRenamed) }
        .outsideDismissibleSheet(item: $deleting) { JournalDeleteSheet(entry: $0, store: store, onDeleted: onDeleted) }
    }

    private func snapshot() -> JournalDraft {
        var draft = row
        draft.expectedVersion = max(row.expectedVersion, store.entries.first(where: { $0.id == row.id })?.version ?? 0)
        return draft
    }

}

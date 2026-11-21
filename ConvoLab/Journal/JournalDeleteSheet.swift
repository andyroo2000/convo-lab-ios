import SwiftUI

struct JournalDeleteSheet: View {
    let entry: JournalDraft
    let store: JournalStore
    let onDeleted: () -> Void
    @AppStorage(JournalTypography.fontKey) private var font = JournalTypography.defaultFont
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        JournalDialogSheet {
            Text("Delete this entry?").font(JournalDialogStyle.heading).accessibilityAddTraits(.isHeader)
            Text("This entry will be permanently deleted. You can’t undo this action.")
            preview
            if let errorMessage { Text(errorMessage).foregroundStyle(JournalDialogStyle.destructive) }
            JournalEntryDialogActions {
                Button("Keep entry", role: .cancel) { dismiss() }.buttonStyle(JournalDraftButtonStyle(sage: false))
                Button(busy ? "Deleting…" : "Delete entry", role: .destructive) {
                    Task { await deleteEntry() }
                }.buttonStyle(JournalDraftButtonStyle(destructive: true))
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("JournalDeleteConfirmation")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title ?? "Untitled entry").font(JournalTypography(font: font, size: 23).font)
            Text(JournalDates.display(entry.entryDate)).font(JournalDialogStyle.body).foregroundStyle(.secondary)
            Text(entry.body.isEmpty ? "Empty draft" : entry.body)
                .font(JournalTypography(font: font, size: 20).font).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.white, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(JournalDialogStyle.border) }
    }

    private func deleteEntry() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await store.delete(id: entry.id)
            dismiss()
            onDeleted()
        } catch { errorMessage = error.localizedDescription }
    }
}

import SwiftUI

struct JournalRenameSheet: View {
    let entry: JournalDraft
    let store: JournalStore
    let onSaved: () -> Void
    @AppStorage(JournalTypography.fontKey) private var font = JournalTypography.defaultFont
    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(entry: JournalDraft, store: JournalStore, onSaved: @escaping () -> Void = {}) {
        self.entry = entry
        self.store = store
        self.onSaved = onSaved
        _title = State(initialValue: entry.title ?? "")
    }

    private var valid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.count <= 255
    }

    var body: some View {
        JournalDialogSheet {
            Text("Rename entry").font(JournalDialogStyle.heading).accessibilityAddTraits(.isHeader)
            TextField("Untitled entry", text: $title)
                .font(JournalTypography(font: font, size: 23).font)
                .textFieldStyle(.plain).padding(14)
                .background(.white, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(JournalDialogStyle.border) }
                .accessibilityLabel("Entry title")
                .accessibilityIdentifier("JournalRenameTitle")
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
            if title.unicodeScalars.count > 255 {
                Text("Use 255 characters or fewer.").foregroundStyle(JournalDialogStyle.destructive)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(JournalDialogStyle.destructive) }
            JournalEntryDialogActions {
                Button("Cancel") { dismiss() }.buttonStyle(JournalDraftButtonStyle(sage: false))
                Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(JournalDraftButtonStyle()).disabled(!valid)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .task { titleFocused = true }
    }

    private func save() async {
        guard !isSaving, valid else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await store.rename(entry, title: title)
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

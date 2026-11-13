import SwiftUI

struct JournalRenameSheet: View {
    let entry: JournalDraft
    let store: JournalStore
    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(entry: JournalDraft, store: JournalStore) {
        self.entry = entry
        self.store = store
        _title = State(initialValue: entry.title ?? "")
    }

    private var valid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.count <= 255
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Rename entry").font(.title2.bold())
                TextField("Untitled entry", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Entry title")
                    .accessibilityIdentifier("JournalRenameTitle")
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                if title.unicodeScalars.count > 255 {
                    Text("Use 255 characters or fewer.").font(.footnote).foregroundStyle(.red)
                }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent).disabled(!valid)
                }
            }.padding(24).disabled(isSaving)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

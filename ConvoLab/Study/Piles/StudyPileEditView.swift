import SwiftUI

struct StudyPileEditView: View {
    let store: StudyStore
    let item: StudyPileChapter?
    let pileID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var id: String
    @State private var title: String
    @State private var position: String
    @State private var saving = false
    @State private var error: String?

    init(store: StudyStore, item: StudyPileChapter? = nil, pileID: String? = nil, position: Int = 0) {
        self.store = store
        self.item = item
        self.pileID = pileID
        _id = State(initialValue: item?.id ?? ClientIdentifier.ulid().lowercased())
        _title = State(initialValue: item?.title ?? "")
        _position = State(initialValue: String(item?.position ?? position))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                HStack {
                    Text("Order")
                    TextField("Order", text: $position)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Text("Lower numbers come first. New books and chapters start off.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle(item == nil ? "Add source" : "Edit source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || !valid)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var valid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 160 && Int(position).map { (0...1_000_000).contains($0) } == true
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await store.savePile(id: id, update: StudyPileUpdate(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), position: Int(position)
            ), pileID: pileID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

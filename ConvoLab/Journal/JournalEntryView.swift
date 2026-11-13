import SwiftUI

struct JournalEntryView: View {
    @State private var model: JournalEntryModel
    let knownKanji: Set<Character>
    @AppStorage(JournalTypography.fontKey) private var journalFont = "sans"
    @AppStorage(JournalTypography.sizeKey) private var journalSize = 20.0
    @Environment(\.dismiss) private var dismiss
    @State private var showingDelete = false
    @State private var isDeleting = false
    @State private var copiedID: String?

    init(id: String, store: JournalStore, knownKanji: Set<Character>) {
        _model = State(initialValue: JournalEntryModel(id: id, store: store))
        self.knownKanji = knownKanji
    }

    private var isReviewing: Bool { model.analysis?.status == .ready && model.analysis?.result != nil && !model.isEditing }
    private var pollingKey: String { "\(model.analysis?.id ?? ""):\(model.analysis?.status.rawValue ?? ""):\(model.analysis?.pendingReplyId ?? "")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if model.hasConflict {
                    Button("Save as a new entry") {
                        do { copiedID = try model.copyAsNew() }
                        catch { model.errorMessage = "Could not preserve a separate copy. Keep this entry open." }
                    }
                }
                if isReviewing { JournalConversationView(root: model, knownKanji: knownKanji).id(model.id) } else { JournalEntryForm(model: model, onDelete: { showingDelete = true }) }
                if isReviewing {
                    JournalDeleteButton { showingDelete = true }
                        .disabled(model.isBusy)
                }
                if let analysis = model.analysis, analysis.status.isPending {
                    JournalProgressView(status: analysis.status, serverTime: analysis.updatedAt).id(analysis.id)
                }
                if model.analysis?.status == .failed {
                    Text(model.analysis?.error ?? "Feedback could not be prepared. Try Submit again.").foregroundStyle(.red)
                }
            }.padding(20)
        }
        .disabled(isDeleting)
        .alert("Delete this entry?", isPresented: $showingDelete) {
            Button("Delete entry", role: .destructive) { Task { await deleteEntry() } }
            Button("Keep entry", role: .cancel) {}
        } message: {
            Text("“\(model.draft?.title ?? "Untitled entry")” will be permanently deleted. You can’t undo this action.")
        }
        .environment(\.journalTypography, JournalTypography(font: journalFont, size: journalSize))
        .modifier(JournalTimeTracking(service: model.store.service))
        .paperBackground()
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.load() }
        .task(id: pollingKey) { await model.poll() }
        .navigationDestination(item: $copiedID) { id in
            JournalEntryView(id: id, store: model.store, knownKanji: knownKanji)
        }
    }

    private func deleteEntry() async {
        guard !isDeleting, !model.isBusy else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await model.store.delete(id: model.id)
            dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }

}

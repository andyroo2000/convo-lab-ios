import SwiftUI

struct JournalEntryView: View {
    let store: JournalStore
    let knownKanji: Set<Character>
    @State private var selection: JournalSelection
    @State private var showingEntries = false
    @State private var renameRevision = 0

    init(id: String? = nil, store: JournalStore, knownKanji: Set<Character>) {
        self.store = store
        self.knownKanji = knownKanji
        _selection = State(initialValue: id.map { JournalSelection(id: $0) } ?? .blank())
    }
    var body: some View {
        JournalEntryScreen(selection: selection, store: store, knownKanji: knownKanji, close: showBlank, select: open)
            .id("\(selection.id):\(renameRevision)")
            .environment(\.journalShowEntries, { store.refreshDrafts(); showingEntries = true })
            .sheet(isPresented: $showingEntries) {
                JournalEntriesSheet(store: store, selectedID: selection.id, deleted: { id in
                    if id == selection.id { showBlank() }
                }, renamed: { id in
                    if id == selection.id { renameRevision += 1 }
                }, create: showBlank, select: open)
            }
    }

    private func showBlank() { selection = .blank(); showingEntries = false }
    private func open(_ id: String) { selection = JournalSelection(id: id); showingEntries = false }
}


private struct JournalEntryScreen: View {
    @State private var model: JournalEntryModel
    let knownKanji: Set<Character>
    let close: () -> Void
    let select: (String) -> Void
    let isNew: Bool
    @AppStorage(JournalTypography.fontKey) private var journalFont = JournalTypography.defaultFont
    @AppStorage(JournalTypography.sizeKey) private var journalSize = 20.0
    @State private var copiedID: String?

    init(selection: JournalSelection, store: JournalStore, knownKanji: Set<Character>, close: @escaping () -> Void, select: @escaping (String) -> Void) {
        _model = State(initialValue: JournalEntryModel(id: selection.id, store: store, initialDraft: selection.draft))
        self.knownKanji = knownKanji
        self.close = close
        self.select = select
        isNew = selection.draft != nil
    }

    private var isReviewing: Bool { model.analysis?.status == .ready && model.analysis?.result != nil && !model.isEditing }
    private var pollingKey: String { "\(model.analysis?.id ?? ""):\(model.analysis?.status.rawValue ?? ""):\(model.analysis?.pendingReplyId ?? "")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !isReviewing {
                    HStack { JournalEntriesButton(); Spacer(); JournalAppearanceMenu() }.modifier(JournalDeskStyle())
                }
                if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if model.hasConflict {
                    Button("Save as a new entry") {
                        do { copiedID = try model.copyAsNew() }
                        catch { model.errorMessage = "Could not preserve a separate copy. Keep this entry open." }
                    }
                }
                if model.missingEntry {
                    JournalMissingEntryView()
                } else if model.clarification.active {
                    JournalClarificationView(model: model.clarification, service: model.store.service)
                } else if model.isSubmitting || model.analysis?.status.isPending == true {
                    JournalThinkingView(service: model.store.service, lastAnswer: model.clarification.lastAnswer)
                } else if isReviewing { JournalConversationView(root: model, knownKanji: knownKanji).id(model.id) } else {
                    if isNew && model.draft?.body.isEmpty == true { JournalResumeView(store: model.store, select: select) }
                    JournalEntryForm(model: model, onClose: close)
                }
                if model.analysis?.status == .failed {
                    Text(model.analysis?.error ?? "Feedback could not be prepared. Try Submit again.").foregroundStyle(.red)
                }
            }.padding(20)
        }
        .environment(\.journalTypography, JournalTypography(font: journalFont, size: journalSize))
        .modifier(JournalTimeTracking(service: model.store.service))
        .background(.white)
        .tint(JournalToolbarButtonStyle.blue)
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { model.clarification.cancel() }
        .task { if model.draft == nil { await model.load() } }
        .task(id: pollingKey) { await model.poll() }
        .navigationDestination(item: $copiedID) { id in
            JournalEntryView(id: id, store: model.store, knownKanji: knownKanji)
        }
    }

}

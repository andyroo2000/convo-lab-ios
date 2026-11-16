import SwiftUI

struct JournalEntryView: View {
    let store: JournalStore
    let knownKanji: Set<Character>
    @State private var selectedID: String
    @State private var showingEntries = false

    init(id: String, store: JournalStore, knownKanji: Set<Character>) {
        self.store = store
        self.knownKanji = knownKanji
        _selectedID = State(initialValue: id)
    }
    var body: some View {
        JournalEntryScreen(id: selectedID, store: store, knownKanji: knownKanji).id(selectedID)
            .environment(\.journalShowEntries, { showingEntries = true })
            .sheet(isPresented: $showingEntries) {
                JournalEntriesSheet(store: store, selectedID: selectedID) { id in
                    selectedID = id; showingEntries = false
                }
            }
    }
}


private struct JournalEntryScreen: View {
    @State private var model: JournalEntryModel
    let knownKanji: Set<Character>
    @AppStorage(JournalTypography.fontKey) private var journalFont = JournalTypography.defaultFont
    @AppStorage(JournalTypography.sizeKey) private var journalSize = 20.0
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
                } else if isReviewing { JournalConversationView(root: model, knownKanji: knownKanji).id(model.id) } else { JournalEntryForm(model: model) }
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
        .task { await model.load() }
        .task(id: pollingKey) { await model.poll() }
        .navigationDestination(item: $copiedID) { id in
            JournalEntryView(id: id, store: model.store, knownKanji: knownKanji)
        }
    }

}

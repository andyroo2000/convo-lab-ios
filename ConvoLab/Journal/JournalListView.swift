import SwiftUI

struct JournalListView: View {
    let store: JournalStore
    let knownKanji: Set<Character>
    @State private var initialID: String?
    @State private var resolved = false

    var body: some View {
        Group {
            if resolved { JournalEntryView(id: initialID, store: store, knownKanji: knownKanji) }
            else { ProgressView("Opening Journal…") }
        }
        .onDisappear { resolved = false }
        .task {
            guard !resolved else { return }
            await store.loadMore(refresh: true)
            guard !Task.isCancelled else { return }
            initialID = JournalSelection.today(entries: store.entries, drafts: store.drafts, date: JournalDates.storage.string(from: .now))
            resolved = true
        }
    }
}

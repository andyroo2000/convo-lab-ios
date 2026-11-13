import SwiftUI

struct JournalListView: View {
    let store: JournalStore
    let knownKanji: Set<Character>
    @State private var newEntryID: String?
    @State private var deletingID: String?

    private var rows: [JournalDraft] {
        var merged = Dictionary(store.entries.map { ($0.id, JournalDraft(entry: $0)) }, uniquingKeysWith: { _, newer in newer })
        for draft in store.drafts { merged[draft.id] = draft }
        return merged.values.sorted { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
    }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            ForEach(rows) { row in
                NavigationLink {
                    JournalEntryView(id: row.id, store: store, knownKanji: knownKanji)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title ?? "Untitled entry").font(.headline)
                        Text(JournalDates.display(row.entryDate)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).accessibilityElement(children: .combine)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deletingID = row.id }
                }
            }
            if store.nextCursor != nil {
                Button("Load more") { Task { await store.loadMore() } }.disabled(store.isLoading)
            }
            if store.isLoading { ProgressView() }
        }
        .overlay { if rows.isEmpty && !store.isLoading && store.errorMessage == nil { ContentUnavailableView("No journal entries yet", systemImage: "book.closed") } }
        .scrollContentBackground(.hidden)
        .modifier(JournalTimeTracking(service: store.service))
        .paperBackground()
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New entry", systemImage: "square.and.pencil") {
                    do { newEntryID = try store.create().id }
                    catch { store.errorMessage = "Could not create a device draft. Try again." }
                }
                .accessibilityIdentifier("JournalNewEntry")
            }
        }
        .navigationDestination(item: $newEntryID) { id in
            JournalEntryView(id: id, store: store, knownKanji: knownKanji)
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }), titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                guard let id = deletingID else { return }
                deletingID = nil
                Task {
                    do { try await store.delete(id: id) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        }
        .task {
            store.refreshDrafts()
            if store.entries.isEmpty { await store.loadMore(refresh: true) }
        }
        .refreshable { await store.loadMore(refresh: true) }
    }
}

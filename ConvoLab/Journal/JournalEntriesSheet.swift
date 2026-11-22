import SwiftUI

struct JournalEntriesSheet: View {
    let store: JournalStore
    let selectedID: String
    var deleted: (String) -> Void = { _ in }
    var renamed: (String) -> Void = { _ in }
    var create: () -> Void
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var rows: [JournalDraft] {
        var merged = Dictionary(store.entries.map { ($0.id, JournalDraft(entry: $0)) }, uniquingKeysWith: { _, newer in newer })
        for draft in store.drafts { merged[draft.id] = draft }
        return merged.values.sorted { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(rows) { row in
                    HStack {
                        Button { select(row.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.title ?? "Untitled entry").font(.headline)
                                Text(JournalDates.display(row.entryDate)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                        if row.id == selectedID { Image(systemName: "checkmark").foregroundStyle(JournalDeskStyle.green) }
                        JournalRowActions(row: row, store: store, onDeleted: { deleted(row.id) }, onRenamed: { renamed(row.id) })
                    }
                }
                if store.nextCursor != nil {
                    Button("Load more") { Task { await store.loadMore() } }
                        .disabled(store.isLoading)
                        .onAppear { if store.errorMessage == nil { Task { await store.loadMore() } } }
                }
                if store.isLoading { ProgressView() }
            }
            .refreshable { await store.loadMore(refresh: true) }
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color(red: 1, green: 0.992, blue: 0.961))
            .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New entry", systemImage: "square.and.pencil", action: create).labelStyle(.iconOnly)
                        .accessibilityIdentifier("JournalNewEntry")
                }
            }
            .task(id: scenePhase) { await refreshContents() }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .environment(\.colorScheme, .light).tint(JournalDeskStyle.green)
    }

    private func refreshContents() async {
        guard scenePhase == .active else { return }
        store.refreshDrafts()
        await store.loadMore(refresh: true)
    }

}

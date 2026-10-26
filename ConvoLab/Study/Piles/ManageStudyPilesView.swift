import SwiftUI

struct ManageStudyPilesView: View {
    let store: StudyStore
    @State private var addingBook = false

    var body: some View {
        List {
            Section {
                Text("Choose which books and chapters supply new cards. Pausing a pile never pauses reviews.")
                Text("Lower order numbers come first in the Standard queue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let catalog = store.piles.catalog {
                books("On your shelf", piles: catalog.piles.filter(\.isActive))
                books("Saved for later", piles: catalog.piles.filter { !$0.isActive })
            }
            if store.piles.isRefreshing { ProgressView("Loading piles…") }
            if let error = store.piles.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await store.refreshPiles() } }
                }
            }
            Section {
                Button("Add a book or source", systemImage: "plus") { addingBook = true }
                Text("New books and chapters start off, so you can import ahead of time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Manage piles")
        .refreshable { await store.refreshPiles() }
        .task { await store.refreshPiles() }
        .sheet(isPresented: $addingBook) {
            StudyPileEditView(store: store, position: nextBookPosition)
        }
    }

    private var nextBookPosition: Int { (store.piles.catalog?.piles.map(\.position).max() ?? -1) + 1 }

    private func books(_ title: String, piles: [StudyPile]) -> some View {
        Section(title) {
            if piles.isEmpty { Text("No books here yet.").foregroundStyle(.secondary) }
            ForEach(piles) { pile in StudyPileBookRow(store: store, pile: pile) }
        }
    }
}

struct StudyPileBookRow: View {
    let store: StudyStore
    let pile: StudyPile
    @State private var addingChapter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudyPileToggleRow(store: store, item: pile.summary)
            DisclosureGroup("Chapters (\(pile.chapters.count))") {
                Text("Only enabled chapters supply new cards, in order. Turning a book off keeps these choices. Unlock requirements still apply.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                ForEach(pile.chapters) { chapter in
                    StudyPileToggleRow(store: store, item: chapter, pileID: pile.id)
                        .padding(.vertical, 6)
                }
                Button("Add chapter", systemImage: "plus") { addingChapter = true }
                    .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $addingChapter) {
            StudyPileEditView(store: store, pileID: pile.id, position: (pile.chapters.map(\.position).max() ?? -1) + 1)
        }
    }
}

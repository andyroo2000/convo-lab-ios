import SwiftUI

struct ManageStudyPilesView: View {
    let store: StudyStore
    @State private var activeShelf = true
    @State private var addingBook = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Study piles").font(StudyTimePaper.type(34, .largeTitle)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Add source", systemImage: "plus") { addingBook = true }
                }
                Text("Choose the books and chapters that supply your new cards.").font(.subheadline)
                if let catalog = store.piles.catalog {
                    shelf(catalog.piles)
                }
                if store.piles.isRefreshing { ProgressView("Loading piles…") }
                if let error = store.piles.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await store.refreshPiles() } }
                }
            }.padding()
        }
        .background(StudyTimePaper.desk)
        .foregroundStyle(StudyTimePaper.ink)
        .font(StudyTimePaper.type(18))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshPiles() }
        .task { if !store.piles.isRefreshing { await store.refreshPiles() } }
        .outsideDismissibleSheet(isPresented: $addingBook) {
            StudyPileEditView(store: store, position: nextBookPosition)
        }
    }

    private var nextBookPosition: Int { (store.piles.catalog?.piles.map(\.position).max() ?? -1) + 1 }
    @ViewBuilder
    private func shelf(_ books: [StudyPile]) -> some View {
        let activeCount = books.filter(\.isActive).count
        Picker("Shelf", selection: $activeShelf) {
            Text("On your shelf (\(activeCount))").tag(true)
            Text("Saved for later (\(books.count - activeCount))").tag(false)
        }.pickerStyle(.segmented)
        let visible = books.filter { $0.isActive == activeShelf }
        if visible.isEmpty { Text("No books here yet.").foregroundStyle(.secondary) }
        ForEach(visible) { pile in
            StudyPileBookRow(store: store, pile: pile)
                .padding(14).background(StudyTimePaper.paper, in: .rect(cornerRadius: 7))
        }
    }
}

struct StudyPileBookRow: View {
    let store: StudyStore
    let pile: StudyPile
    @State private var addingChapter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed").padding(9)
                    .background(StudyTimePaper.sage, in: .rect(cornerRadius: 3)).accessibilityHidden(true)
                StudyPileToggleRow(store: store, item: pile.summary)
            }
            DisclosureGroup("Chapters (\(pile.chapters.count))") {
                ForEach(pile.chapters) { chapter in
                    StudyPileToggleRow(store: store, item: chapter, pileID: pile.id)
                        .padding(.vertical, 6)
                }
                Button("Add chapter", systemImage: "plus") { addingChapter = true }
                    .padding(.vertical, 8)
            }.padding(10).background(StudyTimePaper.color(0xe5edf4, 0x283a42), in: .rect(cornerRadius: 6))
        }
        .padding(.vertical, 6)
        .outsideDismissibleSheet(isPresented: $addingChapter) {
            StudyPileEditView(store: store, pileID: pile.id, position: (pile.chapters.map(\.position).max() ?? -1) + 1)
        }
    }
}

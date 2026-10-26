import SwiftUI

struct StudyPileShelf: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a pile").font(.headline)
                Spacer()
                NavigationLink("Manage piles") { ManageStudyPilesView(store: store) }
                    .font(.subheadline.bold())
            }
            Text("Pick a book for new cards. Reviews always stay together.")
                .font(.caption).foregroundStyle(.secondary)
            if let catalog = store.piles.catalog {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tile(id: "learn-soon", title: "Learn soon", count: catalog.learnSoon.readyCount, icon: "bookmark.fill")
                    ForEach(catalog.piles.filter(\.isActive)) { pile in
                        tile(id: pile.id, title: pile.title, count: pile.readyCount, icon: "book.closed.fill")
                    }
                    tile(id: "uncategorized", title: "Uncategorized", count: catalog.uncategorized.readyCount, icon: "square.stack.fill")
                }
            }
            if store.piles.isRefreshing { ProgressView("Loading piles…") }
            if let error = store.piles.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Try again") { Task { await store.refreshPiles() } }
            }
        }
        .padding()
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
        .task { await store.refreshPiles() }
    }

    private func tile(id: String, title: String, count: Int, icon: String) -> some View {
        NavigationLink {
            StudySessionView(store: store, player: player, mode: .lessons, timeStore: timeStore, pileID: id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title).font(.subheadline.bold())
                Text("\(count) ready").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .padding(12)
            .background(ConvoLabTheme.cream, in: .rect(cornerRadius: 10))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(ConvoLabTheme.cyan).frame(width: 5) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 || store.piles.errorMessage != nil)
        .opacity(count == 0 ? 0.5 : 1)
    }
}

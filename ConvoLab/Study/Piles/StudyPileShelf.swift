import SwiftUI

struct StudyPileShelf: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a pile").font(StudyTimePaper.type(22, .headline))
                Spacer()
                NavigationLink("Manage piles") { ManageStudyPilesView(store: store) }
                    .font(StudyTimePaper.type(17))
            }
            Text("Start a lesson from a single pile instead of your usual queue.")
                .font(.caption).foregroundStyle(.secondary)
            if let catalog = store.piles.catalog {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 12) {
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

        .task { await store.refreshPiles() }
    }

    private func tile(id: String, title: String, count: Int, icon: String) -> some View {
        NavigationLink {
            StudySessionView(store: store, player: player, mode: .lessons, timeStore: timeStore, pileID: id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).accessibilityHidden(true)
                Divider()
                VStack(alignment: .leading) {
                    Text(title).font(StudyTimePaper.type(17))
                    Text("\(count) ready").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(StudyTimePaper.paper, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(StudyTimePaper.ink.opacity(0.18)) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) ready")
        .disabled(count == 0 || store.piles.errorMessage != nil)
        .opacity(count == 0 ? 0.5 : 1)
    }
}

import SwiftUI

struct StudyBookSourceFields: View {
    let store: StudyStore
    @Binding var source: StudyBookSource?

    var body: some View {
        Picker("Book or source", selection: Binding(
            get: { source?.pileId ?? "" },
            set: { source = $0.isEmpty ? nil : StudyBookSource(pileId: $0) }
        )) {
            Text("Uncategorized").tag("")
            if let id = source?.pileId, !(store.piles.catalog?.piles.contains { $0.id == id } ?? false) {
                Text("Current source (unavailable)").tag(id)
            }
            ForEach(store.piles.catalog?.piles ?? []) { pile in
                Text(pile.isActive ? pile.title : "\(pile.title) — saved for later").tag(pile.id)
            }
        }
        if source != nil {
            chapterFields
            TextField("Page or reference", text: Binding(
                get: { source?.reference ?? "" },
                set: { source?.reference = $0.isEmpty ? nil : $0 }
            ))
        }
        if let error = store.piles.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Reload sources") { Task { await store.refreshPiles() } }
        }
        NavigationLink("Manage piles") { ManageStudyPilesView(store: store) }
    }

    private var chapterFields: some View {
        let chapters = store.piles.catalog?.piles.first { $0.id == source?.pileId }?.chapters ?? []
        return Picker("Chapter", selection: Binding(
            get: { source?.chapterId ?? "" },
            set: { source?.chapterId = $0.isEmpty ? nil : $0 }
        )) {
            Text("No chapter").tag("")
            if let id = source?.chapterId, !chapters.contains(where: { $0.id == id }) {
                Text("Current chapter (unavailable)").tag(id)
            }
            ForEach(chapters) { chapter in Text(chapter.title).tag(chapter.id) }
        }
    }
}

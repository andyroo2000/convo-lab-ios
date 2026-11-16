import SwiftUI

struct JournalListView: View {
    let store: JournalStore
    let knownKanji: Set<Character>
    @State private var selectedID: String?
    @State private var showingEntries = true

    var body: some View {
        VStack(spacing: 24) {
            HStack { JournalEntriesButton(); Spacer(); JournalAppearanceMenu() }.modifier(JournalDeskStyle())
            Text("Select an entry or start a new one.").font(.custom("CrimsonPro-Regular", size: 20)).foregroundStyle(.secondary)
            Spacer()
        }.padding(20)
            .environment(\.journalShowEntries, { showingEntries = true })
            .modifier(JournalTimeTracking(service: store.service))
            .background(.white)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingEntries) {
                JournalEntriesSheet(store: store, selectedID: "") { id in selectedID = id; showingEntries = false }
            }
            .onChange(of: selectedID) { if selectedID == nil { showingEntries = true } }
            .navigationDestination(item: $selectedID) { id in
                JournalEntryView(id: id, store: store, knownKanji: knownKanji)
            }
    }
}

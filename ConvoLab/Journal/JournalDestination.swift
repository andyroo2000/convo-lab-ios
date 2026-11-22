import SwiftUI

struct JournalDestination: View {
    let api: APIClient
    let userID: Int
    let knownKanji: Set<Character>
    @State private var store: JournalStore?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let store { JournalListView(store: store, knownKanji: knownKanji) }
            else { ProgressView() }
        }.task(id: scenePhase) { await synchronize() }
    }

    private func synchronize() async {
        if store == nil { store = JournalStore(api: api, userID: userID) }
        guard scenePhase == .active, let store else { return }
        let connection = JournalSyncConnectivity(store: store)
        defer { connection.stop() }
        while !Task.isCancelled {
            await store.synchronizeDrafts()
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
        }
    }
}

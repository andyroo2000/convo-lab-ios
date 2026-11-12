import SwiftUI

struct JournalDestination: View {
    let api: APIClient
    let userID: Int
    let knownKanji: Set<Character>
    @State private var store: JournalStore?

    var body: some View {
        Group {
            if let store { JournalListView(store: store, knownKanji: knownKanji) }
            else { ProgressView() }
        }.task {
            if store == nil { store = JournalStore(api: api, userID: userID) }
        }
    }
}

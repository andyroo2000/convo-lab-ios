import SwiftUI

struct JournalDestination: View {
    @State private var store: JournalStore
    let knownKanji: Set<Character>

    init(api: APIClient, userID: Int, knownKanji: Set<Character>) {
        _store = State(initialValue: JournalStore(api: api, userID: userID))
        self.knownKanji = knownKanji
    }

    var body: some View {
        JournalListView(store: store, knownKanji: knownKanji)
    }
}

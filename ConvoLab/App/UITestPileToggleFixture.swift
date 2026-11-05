#if DEBUG
import SwiftData
import SwiftUI

struct UITestPileToggleFixture: View {
    @State private var composition = PileToggleFixtureComposition()

    var body: some View {
        NavigationStack {
            Form {
                if let pile = composition.store.piles.catalog?.piles.first,
                   let chapter = pile.chapters.first {
                    StudyPileToggleRow(store: composition.store, item: chapter, pileID: pile.id)
                }
                if composition.store.piles.isRefreshing {
                    ProgressView("Refreshing counts")
                }
                Section("Test server") {
                    Button("Finish save") { UITestPileToggleProtocol.complete("save") }
                    Button("Fail save") { UITestPileToggleProtocol.complete("save", status: 503) }
                    Button("Finish counts") { UITestPileToggleProtocol.complete("counts") }
                }
            }
            .navigationTitle("Chapter switches")
        }
    }
}

private final class PileToggleFixtureComposition {
    let container: ModelContainer
    let store: StudyStore

    init() {
        container = try! Persistence.makeContainer(inMemory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestPileToggleProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://ui-tests.invalid")!,
                            session: URLSession(configuration: configuration))
        api.setAccessToken("fixture-only-token")
        store = StudyStore(initialUserID: 1, api: api, context: container.mainContext,
                           mediaCache: MediaCache(initialUserID: 1, api: api, context: container.mainContext))
        store.piles.catalog = try! StorageCodec.decoder.decode(
            StudyPileCatalog.self, from: UITestPileToggleProtocol.catalogData
        )
    }
}
#endif

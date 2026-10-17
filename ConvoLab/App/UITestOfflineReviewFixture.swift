#if DEBUG
import SwiftUI
import SwiftData

@MainActor
struct UITestOfflineReviewFixture: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    @State private var selection: AppMode = .study
    @State private var reviewing = true
    @State private var timeStore: StudyTimeStore?
    @State private var timeContainer: ModelContainer?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Study", systemImage: "rectangle.stack", value: AppMode.study) {
                reviewNavigation.toolbar(.hidden, for: .tabBar)
            }
            Tab("Readings", systemImage: "book", value: AppMode.readings) {
                Text("Readings landing").toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .modifier(AppModeHeader(selection: $selection))
        .task { prepareTimeStore() }
    }

    private var reviewNavigation: some View {
        VStack {
            Text("Pending offline reviews: \(store.pendingOfflineReviewCount)")
                .accessibilityIdentifier("pending-offline-review-count")
            NavigationStack {
                VStack {
                    Button("Review cards") { reviewing = true }
                    Text(timeStore?.active == nil ? "Timer stopped" : "Timer running")
                    Text(timeStore?.sessions.isEmpty == false ? "Time record saved" : "No time record")
                }
                .navigationDestination(isPresented: $reviewing) {
                    if let timeStore {
                        StudySessionView(store: store, player: player, timeStore: timeStore)
                    } else { ProgressView() }
                }
            }
        }
    }

    private func prepareTimeStore() {
        guard timeStore == nil else { return }
        do {
            let container = try StudyTimePersistence.makeContainer(inMemory: true)
            let api = APIClient(baseURL: URL(string: "https://ui-tests.invalid")!)
            let time = StudyTimeStore(api: api, context: container.mainContext)
            time.activate(userID: 41)
            timeContainer = container
            timeStore = time
        } catch {
            assertionFailure("Unable to create fixture time store: \(error)")
        }
    }
}
#endif

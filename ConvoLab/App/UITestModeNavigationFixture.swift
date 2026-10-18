#if DEBUG
import SwiftUI

/// Uses the production six-mode shell with isolated storage and intercepted traffic.
struct UITestModeNavigationFixture: View {
    @State private var model: AppModel
    private static let user = CurrentUser(
        id: -205, name: "Navigation fixture", email: "navigation@ui-tests.invalid",
        emailVerifiedAt: nil
    )

    init() {
        let baseURL = URL(string: "https://navigation.ui-tests.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModeNavigationFixtureProtocol.self]
        let api = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let suite = "com.cdcg.convolab.ui-tests.mode-navigation"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        try? ReadingLocalStorage.remove(userID: Self.user.id)
        let model = AppModel(
            configuration: .init(apiBaseURL: baseURL),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in try StudyTimePersistence.makeContainer(inMemory: true) },
            makeAPIClient: { _ in api },
            makeAuthStore: { AuthStore(api: $0, keychain: ModeNavigationCredentialStore(user: Self.user)) },
            makeAudioPlayer: { AudioPlayer(deterministicUITestBackend: ()) },
            accountDeletionCleanupDefaults: defaults
        )
        model.study.activate(userID: Self.user.id)
        model.studyTime.activate(userID: Self.user.id)
        model.dailyAudio.activate(userID: Self.user.id)
        model.mediaCache.activate(userID: Self.user.id)
        model.study.setOverview(StudyOverview(
            dueCount: 2, newCount: 2, reviewCount: 2, totalCards: 4,
            newCardsPerDay: 10, newCardsAvailableToday: 2,
            masterySpread: StudyMasterySpread(apprentice: 2, guru: 1, master: 1, enlightened: 0, burned: 0)
        ))
        _model = State(initialValue: model)
    }

    var body: some View {
        MainModeView(model: model, user: Self.user)
            .modelContainer(model.container)
    }
}

private final class ModeNavigationCredentialStore: CredentialStore {
    private var values: [String: String]

    init(user: CurrentUser) {
        values = [
            "learning-os-mobile-token": "navigation-fixture",
            "learning-os-current-user": String(decoding: try! JSONEncoder().encode(user), as: UTF8.self),
        ]
    }

    func save(_ value: String, account: String) throws { values[account] = value }
    func read(account: String) throws -> String? { values[account] }
    func remove(account: String) throws { values.removeValue(forKey: account) }
}
#endif

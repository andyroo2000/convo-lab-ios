#if DEBUG
import SwiftUI

/// A process-level entry point for native UI tests. Fixture launches never construct
/// the production AppModel graph; feature-specific compositions can supply isolated
/// stores and dependencies without opening normal SwiftData stores or audio services.
enum UITestFixture: String {
    case loginScreen = "login-screen"
    case loginRestoration = "login-restoration"
    case offlineReview = "offline-review"
    case createCardRecovery = "create-card-recovery"
    case dailyAudioPlayback = "daily-audio-playback"
    case calendarConnection = "calendar-connection"
    case achievementBadges = "achievement-badges"

    static func fromProcessArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard let marker = arguments.firstIndex(of: "-ui-test-fixture"),
              arguments.indices.contains(marker + 1)
        else { return nil }
        return Self(rawValue: arguments[marker + 1])
    }
}

struct UITestFixtureView: View {
    let fixture: UITestFixture

    var body: some View {
        switch fixture {
        case .loginScreen:
            UITestLoginScreenFixture()
        case .loginRestoration, .offlineReview, .createCardRecovery,
             .dailyAudioPlayback, .calendarConnection, .achievementBadges:
            UITestRealFlowFixtureView(fixture: fixture)
        }
    }
}

private struct UITestLoginScreenFixture: View {
    @State private var auth = AuthStore(
        api: APIClient(baseURL: Self.apiBaseURL),
        keychain: EmptyUITestCredentialStore()
    )

    private static var apiBaseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ui-tests.invalid"
        guard let url = components.url else {
            preconditionFailure("The fixed UI-test API URL must be valid")
        }
        return url
    }

    var body: some View {
        LoginView(auth: auth) {}
            .task { await auth.restore() }
    }
}

private struct EmptyUITestCredentialStore: CredentialStore {
    func save(_ value: String, account: String) throws {}
    func read(account: String) throws -> String? { nil }
    func remove(account: String) throws {}
}
#endif

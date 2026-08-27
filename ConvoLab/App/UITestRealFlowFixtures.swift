#if DEBUG
import Foundation
import SwiftData
import SwiftUI

@MainActor
struct UITestRealFlowFixtureView: View {
    @StateObject private var composition: UITestRealFlowComposition

    init(fixture: UITestFixture) {
        _composition = StateObject(
            wrappedValue: UITestRealFlowComposition(fixture: fixture)
        )
    }

    var body: some View {
        if let content = composition.content {
            content
        } else {
            ContentUnavailableView(
                "UI test fixture failed",
                systemImage: "exclamationmark.triangle",
                description: Text(composition.constructionError ?? "Unknown fixture error")
            )
            .accessibilityIdentifier("ui-test-fixture-error")
        }
    }
}

@MainActor
private final class UITestRealFlowComposition: ObservableObject {
    let content: AnyView?
    let constructionError: String?
    private let retainedObjects: [Any]

    init(fixture: UITestFixture) {
        do {
            let result: Result
            switch fixture {
            case .loginRestoration:
                result = try Self.loginRestoration()
            case .offlineReview:
                result = try Self.offlineReview()
            case .createCardRecovery:
                result = try Self.createCardRecovery()
            case .dailyAudioPlayback:
                result = try Self.dailyAudioPlayback()
            case .calendarConnection:
                result = try Self.calendarConnection()
            case .achievementBadges:
                result = Self.achievementBadges()
            case .loginScreen:
                result = (AnyView(EmptyView()), [])
            }
            content = result.content
            constructionError = nil
            retainedObjects = result.retained
        } catch {
            content = nil
            constructionError = error.localizedDescription
            retainedObjects = []
        }
    }

    private typealias Result = (content: AnyView, retained: [Any])
    private static let userID = 41

    private static func loginRestoration() throws -> Result {
        let api = mockAPI()
        let credentialStore = try UITestCredentialStore(
            name: "login-restoration",
            reset: shouldReset,
            user: fixtureUser
        )
        let model = AppModel(
            configuration: .init(apiBaseURL: fixtureBaseURL),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in try StudyTimePersistence.makeContainer(inMemory: true) },
            makeAPIClient: { _ in api },
            makeAuthStore: { AuthStore(api: $0, keychain: credentialStore) },
            makeAudioPlayer: { AudioPlayer(deterministicUITestBackend: ()) }
        )
        return (
            AnyView(
                RootView(model: model)
                    .modelContainer(model.container)
                    .task { await model.start() }
            ),
            [model, credentialStore]
        )
    }

    private static func offlineReview() throws -> Result {
        let container = try persistentContainer(named: "offline-review")
        if try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty {
            let card = fixtureReviewCard
            container.mainContext.insert(LocalCardRecord(
                card: card,
                userID: userID,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            ))
            try container.mainContext.save()
        }
        let api = mockAPI()
        let mediaCache = MediaCache(
            initialUserID: userID,
            api: api,
            context: container.mainContext
        )
        let store = StudyStore(
            initialUserID: userID,
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache,
            reviewEventOutboxFlushOverride: {
                throw URLError(.notConnectedToInternet)
            }
        )
        let player = StudyAudioPlayer(isLongFormAudioPlaying: { false })
        return (
            AnyView(NavigationStack {
                UITestOfflineReviewFixture(store: store, player: player)
            }),
            [container, api, mediaCache, store, player]
        )
    }

    private static func createCardRecovery() throws -> Result {
        let container = try persistentContainer(named: "create-card-recovery")
        let api = mockAPI()
        let mediaCache = MediaCache(
            initialUserID: userID,
            api: api,
            context: container.mainContext
        )
        let store = StudyStore(
            initialUserID: userID,
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let player = StudyAudioPlayer(isLongFormAudioPlaying: { false })
        return (
            AnyView(CardLibraryView(
                store: store,
                player: player,
                timeStore: nil
            )),
            [container, api, mediaCache, store, player]
        )
    }

    private static func dailyAudioPlayback() throws -> Result {
        let container = try Persistence.makeContainer(inMemory: true)
        let practice = fixtureDailyAudioPractice
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: userID,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
        let api = mockAPI(allowsFixtureAudio: true)
        let mediaCache = MediaCache(
            initialUserID: userID,
            api: api,
            context: container.mainContext
        )
        let store = DailyAudioStore(
            initialUserID: userID,
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let player = AudioPlayer(deterministicUITestBackend: ())
        return (
            AnyView(NavigationStack {
                DailyAudioPlayerView(
                    track: practice.tracks[0],
                    store: store,
                    player: player
                )
            }),
            [container, api, mediaCache, store, player]
        )
    }

    private static func calendarConnection() throws -> Result {
        let api = mockAPI()
        let service = UITestGoogleCalendarService()
        let authorizer = UITestGoogleCalendarAuthorizer(service: service)
        let model = AppModel(
            configuration: .init(apiBaseURL: fixtureBaseURL),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in try StudyTimePersistence.makeContainer(inMemory: true) },
            makeAPIClient: { _ in api },
            makeAuthStore: { AuthStore(api: $0, keychain: UITestCredentialStore.memory()) },
            makeStudyTimeStore: { api, context, storageMode in
                StudyTimeStore(
                    api: api,
                    context: context,
                    storageMode: storageMode,
                    googleCalendar: service,
                    googleCalendarAuthorizer: authorizer
                )
            },
            makeAudioPlayer: { AudioPlayer(deterministicUITestBackend: ()) }
        )
        model.study.activate(userID: userID)
        model.dailyAudio.activate(userID: userID)
        model.studyTime.activate(userID: userID)
        model.mediaCache.activate(userID: userID)
        return (
            AnyView(SettingsView(model: model, user: fixtureUser)),
            [model, service, authorizer]
        )
    }

    private static func achievementBadges() -> Result {
        let baseURL = "https://raw.githubusercontent.com/andyroo2000/learning-os/27aa58cc26f986b7b63c1da32613da79b2447a3e/public/achievement-assets"
        let badges = [
            UITestAchievementBadge(
                achievement: fixtureAchievement(
                    familyKey: "card-muncher",
                    familyTitle: "Card Muncher",
                    metricKey: "reviews.count",
                    unit: "reviews",
                    tierKey: "first-nibble",
                    tierTitle: "First Nibble",
                    threshold: 25,
                    currentValue: 0,
                    description: "A hungry kaiju discovers its first review cards."
                ),
                imageURL: URL(string: "\(baseURL)/card-muncher-series-v1/first-nibble/locked-512.png")!
            ),
            UITestAchievementBadge(
                achievement: fixtureAchievement(
                    familyKey: "roarer",
                    familyTitle: "Roarer",
                    metricKey: "study.conversation.minutes",
                    unit: "minutes",
                    tierKey: "first-roar",
                    tierTitle: "First Roar",
                    threshold: 5,
                    currentValue: 8,
                    description: "A brave little kaiju finds its conversational voice."
                ),
                imageURL: URL(string: "\(baseURL)/roarer-series-v7/first-roar/earned-512.png")!
            ),
            UITestAchievementBadge(
                achievement: fixtureAchievement(
                    familyKey: "yearfire",
                    familyTitle: "Matsuri Light",
                    metricKey: "cards.stability_365d.count",
                    unit: "cards",
                    tierKey: "first-ember",
                    tierTitle: "First Ember",
                    threshold: 25,
                    currentValue: 4,
                    description: "The first lantern glows for cards remembered across a full year."
                ),
                imageURL: URL(string: "\(baseURL)/matsuri-light-series-v1/first-ember/locked-512.png")!
            ),
        ]
        return (
            AnyView(NavigationStack {
                UITestAchievementBadgeGallery(badges: badges)
            }),
            []
        )
    }

    private static func fixtureAchievement(
        familyKey: String,
        familyTitle: String,
        metricKey: String,
        unit: String,
        tierKey: String,
        tierTitle: String,
        threshold: Int,
        currentValue: Int,
        description: String
    ) -> PresentedStudyAchievement {
        let isEarned = currentValue >= threshold
        let imageSize = StudyAchievementAsset(path: "/fixture.png", width: 512, height: 512)
        let imageAssets = StudyAchievementPNGAssets(png: ["512": imageSize])
        return PresentedStudyAchievement(
            family: StudyAchievementFamily(
                key: familyKey,
                title: familyTitle,
                metricKey: metricKey,
                unit: unit,
                tiers: []
            ),
            tier: StudyAchievementTier(
                key: tierKey,
                title: tierTitle,
                threshold: threshold,
                description: description,
                assets: StudyAchievementTierAssets(earned: imageAssets, locked: imageAssets)
            ),
            isEarned: isEarned,
            currentValue: currentValue,
            remaining: max(0, threshold - currentValue)
        )
    }

    private static var shouldReset: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_RESET"] == "1"
    }

    private static var fixtureBaseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ui-tests.invalid"
        guard let url = components.url else {
            preconditionFailure("The fixed UI-test API URL must be valid")
        }
        return url
    }

    private static func mockAPI(allowsFixtureAudio: Bool = false) -> APIClient {
        UITestURLProtocol.allowsFixtureAudio = allowsFixtureAudio
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestURLProtocol.self]
        return APIClient(
            baseURL: fixtureBaseURL,
            session: URLSession(configuration: configuration)
        )
    }

    private static func persistentContainer(named name: String) throws -> ModelContainer {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "ConvoLabUITests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let storeURL = directory.appending(path: "\(name).store")
        if shouldReset {
            for url in [
                storeURL,
                URL(filePath: storeURL.path + "-shm"),
                URL(filePath: storeURL.path + "-wal"),
            ] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return try Persistence.makeContainer(storeURL: storeURL)
    }

    private static let fixtureUser = CurrentUser(
        id: userID,
        name: "UI Test Learner",
        email: "learner@ui-tests.invalid",
        emailVerifiedAt: nil
    )

    private static var fixtureReviewCard: StudyCard {
        StudyCard(
            id: "01JUITESTOFFLINEREVIEW0000",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("復習する")]),
            answer: .object(["meaning": .string("to review")]),
            state: .init(
                dueAt: .distantPast,
                introducedAt: .distantPast,
                failedAt: nil,
                queueState: "review",
                scheduler: .object([
                    "stability": .number(45),
                    "difficulty": .number(4),
                    "reps": .number(8),
                    "state": .number(2),
                ]),
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private static var fixtureDailyAudioPractice: DailyAudioPractice {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return DailyAudioPractice(
            id: "ui-test-practice",
            practiceDate: "2026-08-25",
            status: "ready",
            targetDurationMinutes: 5,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now,
            tracks: [DailyAudioTrack(
                id: "ui-test-track",
                practiceId: "ui-test-practice",
                mode: "shadowing",
                status: "ready",
                title: "Deterministic Daily Audio",
                sortOrder: 0,
                scriptUnitsJson: [.init(
                    type: "line",
                    text: "今日は日本語を練習します。",
                    reading: "きょうはにほんごをれんしゅうします。",
                    translation: "Today I will practice Japanese."
                )],
                audioUrl: "https://ui-tests.invalid/audio/test.mp3",
                timingData: [.init(unitIndex: 0, startTime: 0, endTime: 60)],
                approxDurationSeconds: 60,
                updatedAt: now
            )]
        )
    }
}

private struct UITestAchievementBadge: Identifiable {
    let achievement: PresentedStudyAchievement
    let imageURL: URL

    var id: String { achievement.id }
}

private struct UITestAchievementBadgeGallery: View {
    let badges: [UITestAchievementBadge]

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACHIEVEMENTS")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(ConvoLabTheme.coral)
                    Text("Your roar is growing")
                        .font(.largeTitle.bold())
                        .foregroundStyle(ConvoLabTheme.navy)
                }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(badges) { badge in
                        StudyAchievementBadgeCard(
                            achievement: badge.achievement,
                            imageURL: badge.imageURL
                        )
                    }
                }
            }
            .padding(28)
        }
        .paperBackground()
        .accessibilityIdentifier("achievement-badge-gallery")
    }
}

@MainActor
private struct UITestOfflineReviewFixture: View {
    let store: StudyStore
    let player: StudyAudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            Text("Pending offline reviews: \(store.pendingOfflineReviewCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pending-offline-review-count")
            StudySessionView(store: store, player: player)
        }
    }
}

private nonisolated final class UITestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var allowsFixtureAudio = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.httpMethod == "POST",
           request.url?.path == "/api/study/card-drafts",
           let url = request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: 503,
               httpVersion: nil,
               headerFields: ["Content-Type": "application/json"]
           )
        {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                self,
                didLoad: Data(#"{"message":"Fixture service is unavailable."}"#.utf8)
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard Self.allowsFixtureAudio,
              request.url?.path == "/audio/test.mp3",
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "audio/mpeg"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture-audio".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UITestCredentialStore: CredentialStore {
    private let defaults: UserDefaults

    private init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    convenience init(name: String, reset: Bool, user: CurrentUser) throws {
        let suite = "com.cdcg.convolab.ui-tests.\(name)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw UITestFixtureConstructionError.unavailableDefaults
        }
        if reset { defaults.removePersistentDomain(forName: suite) }
        self.init(defaults: defaults)
        try save("ui-test-token", account: "learning-os-mobile-token")
        let data = try JSONEncoder().encode(user)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw UITestFixtureConstructionError.invalidUser
        }
        try save(encoded, account: "learning-os-current-user")
    }

    static func memory() -> UITestCredentialStore {
        UITestCredentialStore(defaults: UserDefaults())
    }

    func save(_ value: String, account: String) throws { defaults.set(value, forKey: account) }
    func read(account: String) throws -> String? { defaults.string(forKey: account) }
    func remove(account: String) throws { defaults.removeObject(forKey: account) }
}

private final class UITestGoogleCalendarService: GoogleCalendarConnectionServing {
    var connected = false

    func status() async throws -> GoogleCalendarConnectionStatus {
        GoogleCalendarConnectionStatus(
            connected: connected,
            accountEmail: connected ? "calendar@ui-tests.invalid" : nil,
            scopes: connected ? ["calendar.readonly"] : [],
            settings: nil,
            connectedAt: connected ? .now : nil,
            lastSyncedAt: nil
        )
    }

    func authorizationURL() async throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/ui-test"
        guard let url = components.url else {
            throw GoogleCalendarConnectionError.invalidAuthorizationURL
        }
        return url
    }

    func calendars() async throws -> GoogleCalendarListResponse {
        .init(calendars: [], truncated: false)
    }

    func preview(_ request: GoogleCalendarPreviewRequest) async throws -> GoogleCalendarPreviewResponse {
        throw GoogleCalendarConnectionError.requestFailed
    }

    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings {
        settings
    }

    func sync() async throws -> GoogleCalendarConnectionStatus { try await status() }
    func disconnect() async throws { connected = false }
}

private final class UITestGoogleCalendarAuthorizer: GoogleCalendarAuthorizing {
    let service: UITestGoogleCalendarService

    init(service: UITestGoogleCalendarService) { self.service = service }

    func authorize(at url: URL) async throws -> URL {
        service.connected = true
        var components = URLComponents()
        components.scheme = "convolab"
        components.host = "study-time"
        components.queryItems = [.init(name: "calendarConnection", value: "connected")]
        guard let callback = components.url else {
            throw GoogleCalendarConnectionError.invalidCallback
        }
        return callback
    }
}

private enum UITestFixtureConstructionError: LocalizedError {
    case unavailableDefaults
    case invalidUser

    var errorDescription: String? {
        switch self {
        case .unavailableDefaults: "Could not create isolated UI-test credentials."
        case .invalidUser: "Could not encode the UI-test user."
        }
    }
}
#endif

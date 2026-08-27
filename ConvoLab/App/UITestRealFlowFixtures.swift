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
            case .studyDashboard:
                result = try Self.studyDashboard()
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

    private static func studyDashboard() throws -> Result {
        let container = try Persistence.makeContainer(inMemory: true)
        let timeContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        _ = URLProtocol.registerClass(UITestURLProtocol.self)
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
        store.setOverview(StudyOverview(
            dueCount: 18,
            newCount: 6,
            reviewCount: 18,
            totalCards: 846,
            newCardsPerDay: 10,
            newCardsAvailableToday: 6,
            masterySpread: StudyMasterySpread(
                apprentice: 183,
                guru: 276,
                master: 164,
                enlightened: 118,
                burned: 105
            ),
            learningReadiness: StudyLearningReadiness(
                recommendation: "ready",
                readinessLevel: "steady",
                displayStatus: "Ready to learn",
                displaySummary: "Recent recall is 93%. Target is 90%. You have 183 Apprentice cards, with 126 reviews projected over the next 7 days.",
                sampleSize: 80,
                sufficientData: true,
                recentRecall: 0.93,
                targetRecall: 0.9,
                dueBacklog: 18,
                apprenticeCount: 183,
                projectedSevenDayReviews: 126,
                timedReviewSampleSize: 80,
                medianReviewDurationSeconds: 14,
                projectedDailyReviewMinutes: 5,
                reviewTimeBudgetMinutes: 90,
                reviewTimeHeadroomMinutes: 85,
                suggestedBatchSize: 5
            )
        ))
        let achievementStore = StudyAchievementStore(api: api)
        achievementStore.activate(userID: userID)
        let milestoneStore = StudyMilestoneStore(
            defaults: try fixtureDefaults(named: "study-dashboard-milestones")
        )
        milestoneStore.activate(userID: userID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextLessonStart = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2027,
            month: 8,
            day: 31,
            hour: 14,
            minute: 30
        ).date!
        let calendarService = UITestGoogleCalendarService(
            connected: true,
            nextLesson: GoogleCalendarNextLesson(
                title: "iTalki with Yuki",
                startsAt: nextLessonStart,
                endsAt: nextLessonStart.addingTimeInterval(60 * 60)
            )
        )
        let timeStore = StudyTimeStore(
            api: api,
            context: timeContainer.mainContext,
            googleCalendar: calendarService
        )
        timeStore.activate(userID: userID)
        let player = StudyAudioPlayer(isLongFormAudioPlaying: { false })
        return (
            AnyView(StudyHomeView(
                store: store,
                player: player,
                timeStore: timeStore,
                milestoneStore: milestoneStore,
                achievementStore: achievementStore
            )),
            [
                container,
                timeContainer,
                api,
                mediaCache,
                store,
                achievementStore,
                milestoneStore,
                calendarService,
                timeStore,
                player,
            ]
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

    private static func fixtureDefaults(named name: String) throws -> UserDefaults {
        let suite = "com.cdcg.convolab.ui-tests.\(name)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw UITestFixtureConstructionError.unavailableDefaults
        }
        if shouldReset { defaults.removePersistentDomain(forName: suite) }
        return defaults
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
        if request.url?.path.hasPrefix("/achievement-assets/") == true {
            succeed(with: Self.fixturePNG, contentType: "image/png")
            return
        }
        if request.url?.path == "/api/achievements/catalog" {
            succeed(with: Self.achievementCatalog)
            return
        }
        if request.httpMethod == "POST", request.url?.path == "/api/achievements/evaluate" {
            succeed(with: Data(
                #"{"revision":"achievement-collection-v2","metricValues":{"cards.stability_365d.count":25,"reviews.count":25,"study.conversation.hours":25},"awards":[{"id":"roarer.first-roar","earnedAt":"2026-02-01T00:00:00.000Z"},{"id":"yearfire.first-ember","earnedAt":"2026-01-01T00:00:00.000Z"}]}"#.utf8
            ))
            return
        }
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

    private func succeed(with data: Data, contentType: String = "application/json") {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": contentType]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static let fixturePNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static let achievementCatalog = Data(
        #"""
        {
          "revision":"achievement-collection-v2",
          "presentation":{"targetVisibleBadgeCount":3,"fillWithLockedCandidates":true,"noDataFallbackTierIds":["yearfire.first-ember","card-muncher.first-nibble","roarer.first-roar"]},
          "families":[
            {"key":"yearfire","title":"Matsuri Light","metricKey":"cards.stability_365d.count","unit":"cards","tiers":[{"key":"first-ember","title":"First Ember","threshold":25,"description":"25 cards have reached one year of memory stability.","earnedDescription":"Kept 25 cards stable for a year","assets":{"earned":{"png":{"256":{"path":"/achievement-assets/matsuri-light-series-v1/first-ember/earned-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/matsuri-light-series-v1/first-ember/earned-512.png","width":512,"height":512}}},"locked":{"png":{"256":{"path":"/achievement-assets/matsuri-light-series-v1/first-ember/locked-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/matsuri-light-series-v1/first-ember/locked-512.png","width":512,"height":512}}}}}]},
            {"key":"card-muncher","title":"Card Muncher","metricKey":"reviews.count","unit":"reviews","tiers":[{"key":"first-nibble","title":"First Nibble","threshold":100,"description":"Complete 100 reviews.","earnedDescription":"Completed 100 reviews","assets":{"earned":{"png":{"256":{"path":"/achievement-assets/card-muncher-series-v1/first-nibble/earned-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/card-muncher-series-v1/first-nibble/earned-512.png","width":512,"height":512}}},"locked":{"png":{"256":{"path":"/achievement-assets/card-muncher-series-v1/first-nibble/locked-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/card-muncher-series-v1/first-nibble/locked-512.png","width":512,"height":512}}}}}]},
            {"key":"roarer","title":"Roarer","metricKey":"study.conversation.hours","unit":"hours","tiers":[{"key":"first-roar","title":"First Roar","threshold":1,"description":"Log 1 hour of target-language conversation study.","earnedDescription":"Spoke for 1 hour","assets":{"earned":{"png":{"256":{"path":"/achievement-assets/roarer-series-v7/first-roar/earned-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/roarer-series-v7/first-roar/earned-512.png","width":512,"height":512}}},"locked":{"png":{"256":{"path":"/achievement-assets/roarer-series-v7/first-roar/locked-256.png","width":256,"height":256},"512":{"path":"/achievement-assets/roarer-series-v7/first-roar/locked-512.png","width":512,"height":512}}}}}]}
          ]
        }
        """#.utf8
    )

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
    var connected: Bool
    var nextLesson: GoogleCalendarNextLesson?

    init(
        connected: Bool = false,
        nextLesson: GoogleCalendarNextLesson? = nil
    ) {
        self.connected = connected
        self.nextLesson = nextLesson
    }

    func status() async throws -> GoogleCalendarConnectionStatus {
        GoogleCalendarConnectionStatus(
            connected: connected,
            accountEmail: connected ? "calendar@ui-tests.invalid" : nil,
            scopes: connected ? ["calendar.readonly"] : [],
            settings: nil,
            connectedAt: connected ? .now : nil,
            lastSyncedAt: nil,
            nextLesson: connected ? nextLesson : nil
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

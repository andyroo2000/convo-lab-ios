import Foundation
import SwiftData

@Observable
final class AppModel {
    let container: ModelContainer
    let studyTimeContainer: ModelContainer
    let api: APIClient
    let auth: AuthStore
    let mediaCache: MediaCache
    let study: StudyStore
    let dailyAudio: DailyAudioStore
    let audioPlayer: AudioPlayer
    let studyAudioPlayer: StudyAudioPlayer
    let studyTime: StudyTimeStore
    let isUsingEphemeralStorage: Bool
    @ObservationIgnored private var shouldClaimLegacyData = false

    init(configuration: AppConfiguration = .load()) {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
            isUsingEphemeralStorage = false
        } catch {
            do {
                // Keep the app usable if a future schema change makes the on-disk store
                // unreadable. Server-backed data can still sync while the store is repaired.
                container = try Persistence.makeContainer(inMemory: true)
                isUsingEphemeralStorage = true
            } catch {
                fatalError("Unable to initialize persistent or recovery storage: \(error)")
            }
        }
        let timeContainer: ModelContainer
        do {
            timeContainer = try StudyTimePersistence.makeContainer()
        } catch {
            do {
                timeContainer = try StudyTimePersistence.makeContainer(inMemory: true)
            } catch {
                fatalError("Unable to initialize study time storage: \(error)")
            }
        }
        let api = APIClient(baseURL: configuration.apiBaseURL)
        let mediaCache = MediaCache(api: api, context: container.mainContext)
        let studyTime = StudyTimeStore(api: api, context: timeContainer.mainContext)

        self.container = container
        studyTimeContainer = timeContainer
        self.api = api
        auth = AuthStore(api: api)
        self.mediaCache = mediaCache
        self.studyTime = studyTime
        study = StudyStore(api: api, context: container.mainContext, mediaCache: mediaCache)
        dailyAudio = DailyAudioStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let audioPlayer = AudioPlayer()
        let studyAudioPlayer = StudyAudioPlayer(
            isLongFormAudioPlaying: { [weak audioPlayer] in
                audioPlayer?.isPlaying == true
            }
        )
        audioPlayer.setPlaybackStartHandler { [weak studyAudioPlayer] in
            studyAudioPlayer?.stop()
        }
        audioPlayer.setPlaybackStateHandler { [weak studyTime] isPlaying, title in
            if isPlaying {
                studyTime?.start(
                    activity: .dailyAudio,
                    source: .automatic,
                    name: title.isEmpty ? "Daily Audio" : title
                )
            } else {
                studyTime?.stop(activity: .dailyAudio, source: .automatic)
            }
        }
        self.audioPlayer = audioPlayer
        self.studyAudioPlayer = studyAudioPlayer
    }

    func start() async {
        await auth.restore()
        guard case .signedIn = auth.state else { return }
        // Only a credential restored at cold launch can establish ownership of
        // rows created by the pre-account-scoping app. Never mark the migration
        // complete while running against the emergency in-memory store.
        shouldClaimLegacyData = !isUsingEphemeralStorage
        await refreshAuthenticatedData()
    }

    func synchronize() async {
        if case .signedIn = auth.state {
            await refreshAuthenticatedData()
            return
        }
        await auth.restore()
        guard case .signedIn = auth.state else { return }
        await refreshAuthenticatedData()
    }

    func applicationDidBecomeActive() async {
        study.activateOfflineDueCards()
        if case .signedIn = auth.state {
            async let studySync: Void = study.synchronizeIfNeeded(maxAge: .seconds(300))
            async let dailyAudioRefresh: Void = dailyAudio.refreshIfNeeded(
                maxAge: .seconds(60)
            )
            async let timeSync: Void = studyTime.synchronize()
            _ = await (studySync, dailyAudioRefresh, timeSync)
        }
    }

    func logout() async {
        await studyTime.deactivate()
        audioPlayer.stop()
        studyAudioPlayer.stop()
        study.deactivate()
        dailyAudio.deactivate()
        mediaCache.deactivate()
        await auth.logout()
    }

    func clearDownloadedMedia() throws {
        audioPlayer.stop()
        studyAudioPlayer.stop()
        try mediaCache.clearDownloadedMedia()
    }

    func deleteAccount(currentPassword: String) async -> Bool {
        guard case let .signedIn(user) = auth.state else {
            return false
        }
        let interruptedSession = studyTime.active
        let deletionStartedAt = Date.now
        await studyTime.deactivate(at: deletionStartedAt)
        guard await auth.deleteAccount(currentPassword: currentPassword) else {
            studyTime.activate(userID: user.id)
            if let interruptedSession {
                studyTime.start(
                    activity: interruptedSession.activity,
                    source: interruptedSession.source,
                    name: interruptedSession.name,
                    at: deletionStartedAt
                )
            }
            return false
        }
        audioPlayer.stop()
        studyAudioPlayer.stop()
        study.deactivate()
        dailyAudio.deactivate()
        mediaCache.deactivate()
        try? mediaCache.deleteLocalData(userID: user.id)
        try? dailyAudio.deleteLocalData(userID: user.id)
        try? study.deleteLocalData(userID: user.id)
        try? studyTime.deleteLocalData(userID: user.id)
        return true
    }

    private func refreshAuthenticatedData() async {
        guard case let .signedIn(user) = auth.state else { return }
        // Rows created by pre-account-scoping builds receive SwiftData's zero default
        // during lightweight migration. The first restored signed-in account owns
        // those cards and, critically, any unsent mutation outbox entries.
        if shouldClaimLegacyData {
            do {
                try Persistence.claimLegacyLocalData(
                    for: user.id,
                    context: container.mainContext
                )
                shouldClaimLegacyData = false
            } catch {
                // Leave zero-scoped rows untouched so the same restored account can
                // retry on the next synchronization instead of loading or discarding
                // only part of the outbox.
                return
            }
        }
        mediaCache.activate(userID: user.id)
        study.activate(userID: user.id)
        dailyAudio.activate(userID: user.id)
        studyTime.activate(userID: user.id)
        async let studySync: Void = study.synchronize()
        async let audioRefresh: Bool = dailyAudio.refresh()
        async let timeSync: Void = studyTime.synchronize()
        _ = await (studySync, audioRefresh, timeSync)
    }
}

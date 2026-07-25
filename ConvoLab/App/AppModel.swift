import Foundation
import SwiftData

@Observable
final class AppModel {
    let container: ModelContainer
    let api: APIClient
    let auth: AuthStore
    let mediaCache: MediaCache
    let study: StudyStore
    let dailyAudio: DailyAudioStore
    let audioPlayer: AudioPlayer
    let studyAudioPlayer: StudyAudioPlayer
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
        let api = APIClient(baseURL: configuration.apiBaseURL)
        let mediaCache = MediaCache(api: api, context: container.mainContext)

        self.container = container
        self.api = api
        auth = AuthStore(api: api)
        self.mediaCache = mediaCache
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

    func applicationDidBecomeActive() {
        study.activateOfflineDueCards()
    }

    func logout() async {
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
        guard await auth.deleteAccount(currentPassword: currentPassword) else {
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
        async let studySync: Void = study.synchronize()
        async let audioRefresh: Void = dailyAudio.refresh()
        _ = await (studySync, audioRefresh)
    }
}

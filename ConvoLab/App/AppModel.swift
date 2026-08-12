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
    let storageStatus: StorageStatus
    private(set) var accountDeletionCleanupFailures: [AccountDeletionCleanupFailure] = []
    var accountDeletionCleanupStatus: AccountDeletionCleanupStatus {
        accountDeletionCleanupFailures.isEmpty ? .complete : .cleanupRequired
    }
    var isUsingEphemeralStorage: Bool { storageStatus.study == .temporary }
    @ObservationIgnored private var shouldClaimLegacyData = false
    @ObservationIgnored private let accountDeletionCleanup: AccountDeletionCleanupCoordinator

    init(
        configuration: AppConfiguration = .load(),
        makeContainer: (Bool) throws -> ModelContainer = {
            try Persistence.makeContainer(inMemory: $0)
        },
        makeStudyTimeContainer: (Bool) throws -> ModelContainer = {
            try StudyTimePersistence.makeContainer(inMemory: $0)
        },
        makeAuthStore: (APIClient) -> AuthStore = { AuthStore(api: $0) },
        accountDeletionCleanupDefaults: UserDefaults = .standard
    ) {
        let container: ModelContainer
        let studyStorageMode: StorageMode
        do {
            container = try makeContainer(false)
            studyStorageMode = .persistent
        } catch {
            do {
                // Keep read-only and server-backed features available when an on-disk
                // schema or file error prevents launch, while guarded writes stay disabled.
                container = try makeContainer(true)
                studyStorageMode = .temporary
            } catch {
                fatalError("Unable to initialize persistent or recovery storage: \(error)")
            }
        }
        let timeContainer: ModelContainer
        let studyTimeStorageMode: StorageMode
        do {
            timeContainer = try makeStudyTimeContainer(false)
            studyTimeStorageMode = .persistent
        } catch {
            do {
                // Study-time reads and server refreshes remain useful even though local
                // recording must wait for a launch that can reopen the durable store.
                timeContainer = try makeStudyTimeContainer(true)
                studyTimeStorageMode = .temporary
            } catch {
                fatalError("Unable to initialize study time storage: \(error)")
            }
        }
        let storageStatus = StorageStatus(
            study: studyStorageMode,
            studyTime: studyTimeStorageMode
        )
        let api = APIClient(baseURL: configuration.apiBaseURL)
        let mediaCache = MediaCache(api: api, context: container.mainContext)
        let studyTime = StudyTimeStore(
            api: api,
            context: timeContainer.mainContext,
            storageMode: studyTimeStorageMode
        )
        let study = StudyStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache,
            storageMode: studyStorageMode
        )
        let dailyAudio = DailyAudioStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        self.container = container
        studyTimeContainer = timeContainer
        self.api = api
        auth = makeAuthStore(api)
        self.mediaCache = mediaCache
        self.studyTime = studyTime
        self.storageStatus = storageStatus
        self.study = study
        // Daily Audio creation is server-first and downloaded media is a disposable
        // cache, so those features remain available while study storage is temporary.
        self.dailyAudio = dailyAudio
        let cleanupLedger = AccountDeletionCleanupLedger(
            defaults: accountDeletionCleanupDefaults
        )
        accountDeletionCleanup = AccountDeletionCleanupCoordinator(
            ledger: cleanupLedger,
            operations: [
                .mediaCache: { userID in
                    guard studyStorageMode == .persistent else {
                        return false
                    }
                    do {
                        try mediaCache.deleteLocalData(userID: userID)
                        return true
                    } catch {
                        return false
                    }
                },
                .dailyAudio: { userID in
                    guard studyStorageMode == .persistent else {
                        return false
                    }
                    do {
                        try dailyAudio.deleteLocalData(userID: userID)
                        return true
                    } catch {
                        return false
                    }
                },
                .study: { userID in
                    guard studyStorageMode == .persistent else {
                        return false
                    }
                    do {
                        try study.deleteLocalData(userID: userID)
                        return true
                    } catch {
                        return false
                    }
                },
                .studyTime: { userID in
                    guard studyTimeStorageMode == .persistent else {
                        return false
                    }
                    do {
                        try studyTime.deleteLocalData(userID: userID)
                        return true
                    } catch {
                        return false
                    }
                },
            ]
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
        accountDeletionCleanupFailures = accountDeletionCleanup.pendingFailures
    }

    func start() async {
        // The retry ledger is independent of credentials: account deletion already
        // removed them, and a signed-out relaunch must still finish local purging.
        retryAccountDeletionCleanup()
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
        // If the finish save fails, the durable open row is intentionally
        // recovered when this account next activates.
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
        var serverConfirmedDeletion = false
        // A failed finish remains an open durable row. If deletion is rejected,
        // reactivation below recovers that row instead of creating a duplicate.
        await studyTime.deactivate(at: deletionStartedAt)
        guard await auth.deleteAccount(
            currentPassword: currentPassword,
            onConfirmed: { [accountDeletionCleanup] in
                accountDeletionCleanup.scheduleCleanup(userID: user.id)
                serverConfirmedDeletion = true
            }
        ) else {
            if serverConfirmedDeletion {
                retryAccountDeletionCleanup()
            }
            if case let .signedIn(currentUser) = auth.state,
               currentUser.id == user.id {
                studyTime.activate(userID: user.id)
                if let interruptedSession {
                    studyTime.start(
                        activity: interruptedSession.activity,
                        source: interruptedSession.source,
                        name: interruptedSession.name,
                        at: deletionStartedAt
                    )
                }
            }
            return false
        }
        audioPlayer.stop()
        studyAudioPlayer.stop()
        study.deactivate()
        dailyAudio.deactivate()
        mediaCache.deactivate()
        retryAccountDeletionCleanup()
        return true
    }

    func retryAccountDeletionCleanup() {
        accountDeletionCleanupFailures = accountDeletionCleanup.retryPendingCleanup()
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

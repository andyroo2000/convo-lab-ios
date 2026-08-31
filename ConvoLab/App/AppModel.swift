import Foundation
import SwiftData

struct DailyAudioCompletionMarker: Equatable {
    static let namePrefix = "Daily Audio completed: "
    static let maximumNameLength = 120

    let activity = StudyActivityKind.dailyAudio
    let source = StudyActivitySource.automatic
    let name: String
    let startedAt: Date
    let duration: TimeInterval = 0

    init(title: String, startedAt: Date) {
        let displayTitle = title.isEmpty ? "Daily Audio" : title
        let titleLimit = Self.maximumNameLength - Self.namePrefix.count
        name = Self.namePrefix + String(displayTitle.prefix(titleLimit))
        self.startedAt = startedAt
    }
}

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
    let satoriReaderTracking: SatoriReaderTrackingStore
    let achievements: StudyAchievementStore
    let storageStatus: StorageStatus
    private(set) var accountDeletionCleanupFailures: [AccountDeletionCleanupFailure] = []
    private(set) var isRetryingAccountDeletionCleanup = false
    var accountDeletionCleanupStatus: AccountDeletionCleanupStatus {
        accountDeletionCleanupFailures.isEmpty ? .complete : .cleanupRequired
    }
    var shouldShowAccountDeletionCleanupWarning: Bool {
        guard accountDeletionCleanupStatus == .cleanupRequired,
              !storageStatus.isDegraded
        else { return false }
        if case .signedOut = auth.state { return true }
        return false
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
        makeAPIClient: (URL) -> APIClient = { APIClient(baseURL: $0) },
        makeAuthStore: (APIClient) -> AuthStore = { AuthStore(api: $0) },
        makeStudyTimeStore: ((APIClient, ModelContext, StorageMode) -> StudyTimeStore)? = nil,
        satoriReaderTracking: SatoriReaderTrackingStore = .shared,
        makeAudioPlayer: () -> AudioPlayer = { AudioPlayer() },
        makeStudyAudioPlayer: ((AudioPlayer) -> StudyAudioPlayer)? = nil,
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
        let api = makeAPIClient(configuration.apiBaseURL)
        let mediaCache = MediaCache(api: api, context: container.mainContext)
        let cardCatalogSnapshotCache = StudyCardCatalogSnapshotCache(
            defaults: accountDeletionCleanupDefaults
        )
        let studyTime = makeStudyTimeStore?(api, timeContainer.mainContext, studyTimeStorageMode)
            ?? StudyTimeStore(
                api: api,
                context: timeContainer.mainContext,
                storageMode: studyTimeStorageMode
            )
        let study = StudyStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache,
            storageMode: studyStorageMode,
            cardCatalogSnapshotCache: cardCatalogSnapshotCache
        )
        let dailyAudio = DailyAudioStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let achievements = StudyAchievementStore(
            api: api,
            mediaCache: mediaCache,
            defaults: accountDeletionCleanupDefaults
        )

        self.container = container
        studyTimeContainer = timeContainer
        self.api = api
        auth = makeAuthStore(api)
        self.mediaCache = mediaCache
        self.studyTime = studyTime
        self.satoriReaderTracking = satoriReaderTracking
        self.achievements = achievements
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
                        try await mediaCache.deleteLocalDataForAccountDeletion(userID: userID)
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
                    // This cache remains durable even when SwiftData had to fall
                    // back to temporary storage, so purge it on every attempt.
                    cardCatalogSnapshotCache.remove(userID: userID)
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
                    satoriReaderTracking.removeAccountData(userID: userID)
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
                .milestones: { userID in
                    achievements.deleteLocalData(userID: userID)
                    return true
                },
            ]
        )
        let audioPlayer = makeAudioPlayer()
        let studyAudioPlayer = makeStudyAudioPlayer?(audioPlayer)
            ?? StudyAudioPlayer(
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
        audioPlayer.setPlaybackCompletionHandler { [weak studyTime] title in
            Task { @MainActor in
                let marker = DailyAudioCompletionMarker(title: title, startedAt: .now)
                _ = try? await studyTime?.recordCompleted(
                    activity: marker.activity,
                    source: marker.source,
                    name: marker.name,
                    startedAt: marker.startedAt,
                    duration: marker.duration
                )
            }
        }
        self.audioPlayer = audioPlayer
        self.studyAudioPlayer = studyAudioPlayer
        accountDeletionCleanupFailures = accountDeletionCleanup.pendingFailures
        if case let .signedIn(user) = auth.state {
            if accountDeletionCleanupFailures.contains(where: { $0.userID == user.id }) {
                // The server already confirmed this account's deletion. Do not
                // briefly publish its cached session while local cleanup retries.
                auth.discardCachedSession()
            } else {
                activateLocalData(for: user)
            }
        } else {
            satoriReaderTracking.setActiveUserID(nil)
        }
    }

    func start() async {
        // The retry ledger is independent of credentials: account deletion already
        // removed them, and a signed-out relaunch must still finish local purging.
        await retryAccountDeletionCleanup()
        await auth.restore()
        guard case .signedIn = auth.state else {
            satoriReaderTracking.setActiveUserID(nil)
            return
        }
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
            await importPendingSatoriReaderSessions()
            async let studySync: Void = study.synchronizeIfNeeded(maxAge: .seconds(300))
            async let draftCreateRetry: Void = retryPendingDraftCreates()
            async let dailyAudioRefresh: Void = dailyAudio.refreshIfNeeded(
                maxAge: .seconds(60)
            )
            async let timeSync: Void = studyTime.synchronize()
            async let weeklyRecap: Void = studyTime.loadWeeklyRecap()
            async let achievementRefresh: Void = achievements.refreshIfNeeded(maxAge: 300)
            _ = await (
                studySync,
                draftCreateRetry,
                dailyAudioRefresh,
                timeSync,
                weeklyRecap,
                achievementRefresh
            )
        }
    }

    func logout() async {
        // If the finish save fails, the durable open row is intentionally
        // recovered when this account next activates.
        await studyTime.deactivate()
        audioPlayer.stop()
        studyAudioPlayer.stop()
        study.deactivate()
        achievements.deactivate()
        dailyAudio.deactivate()
        mediaCache.deactivate()
        satoriReaderTracking.setActiveUserID(nil)
        await auth.logout()
    }

    func clearDownloadedMedia() throws {
        audioPlayer.stop()
        studyAudioPlayer.stop()
        try mediaCache.clearDownloadedMedia()
        achievements.downloadedMediaWasCleared()
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
                await retryAccountDeletionCleanup()
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
        achievements.deactivate()
        dailyAudio.deactivate()
        mediaCache.deactivate()
        await retryAccountDeletionCleanup()
        return true
    }

    func retryAccountDeletionCleanup() async {
        guard !isRetryingAccountDeletionCleanup else { return }
        isRetryingAccountDeletionCleanup = true
        defer { isRetryingAccountDeletionCleanup = false }
        // Offer SwiftUI a render opportunity before cleanup begins. Media file
        // removal suspends off-main while this observable guard keeps retry disabled.
        await Task.yield()
        accountDeletionCleanupFailures = await accountDeletionCleanup.retryPendingCleanup()
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
        activateLocalData(for: user)
        await importPendingSatoriReaderSessions()
        async let studyCapabilities: Void = study.refreshCapabilities()
        async let studySync: Void = study.synchronize()
        async let draftCreateRetry: Void = retryPendingDraftCreates()
        async let audioRefresh: Bool = dailyAudio.refresh()
        async let timeSync: Void = studyTime.synchronize()
        async let weeklyRecap: Void = studyTime.loadWeeklyRecap()
        async let achievementRefresh: Void = achievements.refresh()
        _ = await (
            studySync,
            studyCapabilities,
            draftCreateRetry,
            audioRefresh,
            timeSync,
            weeklyRecap,
            achievementRefresh
        )
    }

    private func retryPendingDraftCreates() async {
        // A freshness-throttled study sync can skip its outbox work. Foregrounding
        // still retries durable creates so offline drafts do not wait for a full sync.
        try? await study.retryPendingDraftCreates()
    }

    private func activateLocalData(for user: CurrentUser) {
        mediaCache.activate(userID: user.id)
        study.activate(userID: user.id)
        achievements.activate(userID: user.id)
        dailyAudio.activate(userID: user.id)
        studyTime.activate(userID: user.id)
        satoriReaderTracking.setActiveUserID(user.id)
    }

    func importPendingSatoriReaderSessions() async {
        guard case let .signedIn(user) = auth.state else { return }
        for session in satoriReaderTracking.pendingSessions(userID: user.id) {
            do {
                _ = try await studyTime.recordCompleted(
                    activity: .reading,
                    source: .automatic,
                    name: "Satori Reader",
                    startedAt: session.startedAt,
                    duration: session.duration,
                    clientSessionID: session.id
                )
                satoriReaderTracking.acknowledge(
                    sessionID: session.id,
                    userID: user.id
                )
            } catch {
                // Keep this and later receipts durable so a future foreground
                // activation can retry after storage becomes available.
                break
            }
        }
    }
}

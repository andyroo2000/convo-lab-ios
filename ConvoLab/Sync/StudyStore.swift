import Foundation
import SwiftData

@MainActor
protocol StudyDueActivationScheduling: AnyObject {
    var now: Date { get }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    )

    func cancel()
}

@MainActor
final class RunLoopStudyDueActivationScheduler: StudyDueActivationScheduling {
    private var timer: Timer?

    var now: Date { .now }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let timer = Timer(
            timeInterval: max(0, deadline.timeIntervalSince(now)),
            repeats: false
        ) { _ in
            Task { @MainActor in
                action()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@Observable
final class StudyStore {
    private struct MissingLocalCardError: LocalizedError {
        var errorDescription: String? {
            "This card changed during sync. Close the editor and try again."
        }
    }

    private struct MissingAcknowledgedCardError: LocalizedError {
        var errorDescription: String? {
            "Card sync stopped because its local record is missing. Refresh and try again."
        }
    }

    struct DeletedCardUndoError: LocalizedError {
        var errorDescription: String? {
            "This card was deleted and cannot be restored."
        }
    }

    private struct PendingCardChangesError: LocalizedError {
        let medium: String

        var errorDescription: String? {
            "Sync this card’s pending changes before regenerating its \(medium)."
        }
    }

    private struct CardActionInProgressError: LocalizedError {
        var errorDescription: String? {
            "This card’s review schedule is already being updated."
        }
    }

    struct PendingLearningPathChangesError: LocalizedError {
        var errorDescription: String? {
            "Sync this card’s pending changes before editing its learning path."
        }
    }

    typealias AnswerAudioRegenerationResult = CardAnswerAudioRegenerationResult
    typealias ImageRegenerationResult = CardImageMutationResult

    struct DraftPreviewAudioResult {
        let draft: StudyManualCardDraft
        let localURL: URL?
    }

    struct DraftPreviewImageResult {
        let draft: StudyManualCardDraft
        let localURL: URL
    }

    typealias DraftCommitRecoveryState = ManualDraftCommitRecoveryState

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case offline
        case failed(String)
    }

    let api: APIClient
    let context: ModelContext
    let overviewContext: ModelContext
    let mediaCache: MediaCache
    private let knownKanjiService: KnownKanjiService
    let reviewOutbox: ReviewEventOutbox
    let reviewRecordingService: StudyReviewRecordingService
    let cardOutbox: CardMutationOutbox
    let cardActionOutbox: CardActionOutbox
    let manualDraftOutbox: ManualDraftOutbox
    private let cardMediaService: CardMediaMutationService
    private let pitchAccentService: PitchAccentResolutionService
    let sessionLoadingService: StudySessionLoadingService
    private let syncCoordinator: StudySyncCoordinator
    let localCardRepository: StudyCardLocalRepository
    let cardCatalogRepository: StudyCardCatalogRepository
    let learningPathRepository: StudyLearningPathRepository
    private let dueActivationScheduler: any StudyDueActivationScheduling
#if DEBUG
    private var reviewEventOutboxFlushOverride: (() async throws -> Void)?
#endif
    let diagnostics: NativeDiagnostics
    let deviceID: String
    let storageMode: StorageMode
    @ObservationIgnored private let cardCatalogSnapshotCache: StudyCardCatalogSnapshotCache?
    @ObservationIgnored var cardCatalogSnapshot: StudyCardCatalogSnapshot?
    @ObservationIgnored var newCardQueueRefreshedAt: Date?
    @ObservationIgnored var learningItemsRefreshedAt: Date?
    @ObservationIgnored var learningItemsLocalFallbackOffset: Int?
    @ObservationIgnored var learningItemsLocalFallbackIdentifiers: [[String]]?
    @ObservationIgnored var manualDraftsRefreshedAt: Date?
    @ObservationIgnored var allCardsRefreshRevision = 0
    @ObservationIgnored var learningItemsRefreshRevision = 0
    @ObservationIgnored var newCardQueueRefreshRevision = 0
    @ObservationIgnored var newCardQueueReorderToken: UUID?
    @ObservationIgnored private var pitchAccentResolutionTokens: [String: UUID] = [:]
    @ObservationIgnored var activeUserID: Int?
    @ObservationIgnored var accountActivationGeneration = 0
    @ObservationIgnored var studySettingsMutationRevision = 0
    @ObservationIgnored var studySettingsRefreshID: UUID?
    @ObservationIgnored var studySettingsUpdateID: UUID?
    @ObservationIgnored var overviewRefreshID: UUID?
    @ObservationIgnored var newlyFailedCardIDs: Set<String> = []
    @ObservationIgnored var retainedFailedCardIDs: Set<String> = []
    @ObservationIgnored var resolvedFailedCardIDs: Set<String> = []
    @ObservationIgnored var sessionFailureWasPresentByEventID: [String: Bool] = [:]
    @ObservationIgnored var overviewSnapshot: LocalStudyOverviewSnapshot?
    @ObservationIgnored var overviewSnapshotSaveTask: Task<Void, Never>?
    @ObservationIgnored var studySurfaceRevision = 0
    // Session freshness suppresses redundant UI refreshes. A failed mutation
    // outbox receives one prompt retry before returning to that throttle; the
    // read-only refresh domains use the ordinary max-age cadence.
    @ObservationIgnored var lastSessionRefreshAt: Date?
    @ObservationIgnored private var outboxRetryRevision = 0
    @ObservationIgnored private var consumedOutboxRetryRevision = 0
    @ObservationIgnored var failedStudyChangeOperationIDs: Set<String> = []
    @ObservationIgnored private var cardActionCardIDs: Set<String> = []

    var cards: [StudyCard] = []
    var libraryCards: [StudyCard] = []
    var allCards: [StudyCard] = []
    var allCardsNextCursor: String?
    var allCardsQuery = ""
    var isRefreshingAllCards = false
    var isLoadingMoreAllCards = false
    var learningItems: [StudyLearningItem] = []
    var learningItemsNextCursor: String?
    var learningItemsQuery = ""
    var isRefreshingLearningItems = false
    var isLoadingMoreLearningItems = false
    var newCardQueue: [StudyNewCardQueueItem] = []
    var newCardQueueTotal = 0
    var newCardQueueNextCursor: String?
    var isRefreshingNewCardQueue = false
    var isLoadingMoreNewCardQueue = false
    var storageWriteErrorMessage: String?
    var failedStudyChanges: [FailedStudyChange] = []
    var overview: StudyOverview?
    var offlineReserveMetadata: StudyOfflineReserveMetadata?
    var isRefreshingOverview = false
    var overviewRefreshErrorMessage: String?
    var studySettings: StudySettings?
    var capabilities: StudyCapabilities = .fallback
    var isUpdatingStudySettings = false
    var studySettingsErrorMessage: String?
    var knownKanji: Set<Character> { knownKanjiService.knownKanji }
    var manualKnownKanji: Set<Character> { knownKanjiService.manualKnownKanji }
    var knownKanjiVersion: Int { knownKanjiService.version }
    var wanikaniConnected: Bool { knownKanjiService.wanikaniConnected }
    var wanikaniLastSyncedAt: Date? { knownKanjiService.wanikaniLastSyncedAt }
    var wanikaniReviewCount: Int? { knownKanjiService.wanikaniReviewCount }
    var wanikaniReviewCountUpdatedAt: Date? {
        knownKanjiService.wanikaniReviewCountUpdatedAt
    }
    var wanikaniTransferBridgeEnabled: Bool {
        knownKanjiService.transferBridgeStatus.enabled
    }
    var wanikaniImportedVocabularyCount: Int {
        knownKanjiService.transferBridgeStatus.importedVocabularyCount
    }
    var wanikaniPendingVocabularyCount: Int {
        knownKanjiService.transferBridgeStatus.pendingVocabularyCount
    }
    var wanikaniFailedVocabularyCount: Int {
        knownKanjiService.transferBridgeStatus.failedVocabularyCount
    }
    var wanikaniLastImportedAt: Date? {
        knownKanjiService.transferBridgeStatus.lastImportedAt
    }
    var isWaniKaniWorking: Bool { knownKanjiService.isWorking }
    var wanikaniErrorMessage: String? { knownKanjiService.errorMessage }
    private(set) var resolvingPitchAccentCardIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    var lastSyncAt: Date?
    var sessionInitialCardCount = 0
    var sessionCompletedCardIDs: Set<String> = []
    var sessionFailedCardIDs: Set<String> = []
    var sessionKind = "reviews"
    var reviewOutboxRevision = 0
    var manualDraftOutboxRevision = 0
    var pendingOfflineReviewCount: Int {
        _ = reviewOutboxRevision
        guard activeUserID != nil else { return 0 }
        return (try? reviewOutbox.pendingDeliverableCount()) ?? 0
    }
    var lessonSessionIsPresented = false
    @ObservationIgnored var activeLessonCohortID: String?
    @ObservationIgnored private var activeLessonPresentationID: UUID?
    var masteryAnimation: (
        id: UUID,
        card: StudyCard,
        label: String,
        fromLevel: String,
        toLevel: String,
        passed: Bool
    )?

    var sessionProgress: Double {
        guard sessionInitialCardCount > 0 else { return 0 }
        return min(1, Double(sessionCompletedCardIDs.count) / Double(sessionInitialCardCount))
    }

    var sessionFailureCount: Int {
        sessionFailedCardIDs.count
    }

    func beginSessionFailureTracking() {
        sessionFailedCardIDs = []
        sessionFailureWasPresentByEventID = [:]
    }

    @discardableResult
    func beginLessonSessionPresentation(
        presentationID: UUID = UUID(),
        cohortID: String? = nil
    ) -> Bool {
        if lessonSessionIsPresented {
            return activeLessonPresentationID == presentationID
        }
        studySurfaceRevision += 1
        lessonSessionIsPresented = true
        activeLessonPresentationID = presentationID
        activeLessonCohortID = cohortID
        sessionLoadingService.invalidate()
        dueActivationScheduler.cancel()
        cards = []
        sessionInitialCardCount = 0
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        return true
    }

    func endLessonSessionPresentation(presentationID: UUID? = nil) {
        guard lessonSessionIsPresented else { return }
        if let presentationID, activeLessonPresentationID != presentationID { return }
        studySurfaceRevision += 1
        lessonSessionIsPresented = false
        activeLessonPresentationID = nil
        activeLessonCohortID = nil
        sessionLoadingService.invalidate()
        sessionKind = "reviews"
        if let userID = activeUserID {
            loadLocalCards(userID: userID)
            loadLibraryCards(userID: userID)
        }
        sessionInitialCardCount = cards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        scheduleNextOfflineActivation()
    }

    init(
        initialUserID: Int? = nil,
        api: APIClient,
        context: ModelContext,
        mediaCache: MediaCache,
        storageMode: StorageMode = .persistent,
        cardCatalogSnapshotCache: StudyCardCatalogSnapshotCache? = nil,
        dueActivationScheduler: any StudyDueActivationScheduling = RunLoopStudyDueActivationScheduler(),
        diagnostics: NativeDiagnostics = .shared,
        reviewProjection: @escaping (
            StudyCard,
            ReviewRating,
            Date
        ) throws -> StudyCard = { card, rating, reviewedAt in
            try card.applyingReview(rating, at: reviewedAt)
        }
    ) {
        self.api = api
        self.context = context
        overviewContext = ModelContext(context.container)
        overviewContext.autosaveEnabled = false
        self.mediaCache = mediaCache
        self.storageMode = storageMode
        self.cardCatalogSnapshotCache = cardCatalogSnapshotCache
        self.dueActivationScheduler = dueActivationScheduler
        self.diagnostics = diagnostics
        knownKanjiService = KnownKanjiService(api: api, context: context)
        let reviewOutbox = ReviewEventOutbox(api: api, context: context)
        self.reviewOutbox = reviewOutbox
        reviewRecordingService = StudyReviewRecordingService(
            context: context,
            reviewOutbox: reviewOutbox,
            reviewProjection: reviewProjection
        )
        cardOutbox = CardMutationOutbox(
            api: api,
            context: context,
            reviewOutbox: reviewOutbox
        )
        cardActionOutbox = CardActionOutbox(api: api, context: context)
        manualDraftOutbox = ManualDraftOutbox(api: api, context: context)
        cardMediaService = CardMediaMutationService(api: api, mediaCache: mediaCache)
        pitchAccentService = PitchAccentResolutionService(api: api, context: context)
        sessionLoadingService = StudySessionLoadingService(api: api)
        syncCoordinator = StudySyncCoordinator(
            repository: CardSyncFeedRepository(api: api, context: context)
        )
        localCardRepository = StudyCardLocalRepository(context: context)
        cardCatalogRepository = StudyCardCatalogRepository(api: api)
        learningPathRepository = StudyLearningPathRepository(api: api)
        deviceID = ClientIdentifier.deviceID()
        if let initialUserID {
            activate(userID: initialUserID)
        }
    }

#if DEBUG
    convenience init(
        initialUserID: Int? = nil,
        api: APIClient,
        context: ModelContext,
        mediaCache: MediaCache,
        storageMode: StorageMode = .persistent,
        dueActivationScheduler: any StudyDueActivationScheduling = RunLoopStudyDueActivationScheduler(),
        reviewProjection: @escaping (
            StudyCard,
            ReviewRating,
            Date
        ) throws -> StudyCard = { card, rating, reviewedAt in
            try card.applyingReview(rating, at: reviewedAt)
        },
        reviewEventOutboxFlushOverride: @escaping () async throws -> Void
    ) {
        self.init(
            initialUserID: initialUserID,
            api: api,
            context: context,
            mediaCache: mediaCache,
            storageMode: storageMode,
            cardCatalogSnapshotCache: nil,
            dueActivationScheduler: dueActivationScheduler,
            reviewProjection: reviewProjection
        )
        self.reviewEventOutboxFlushOverride = reviewEventOutboxFlushOverride
    }
#endif

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        deactivate()
        activeUserID = userID
        mediaCache.activate(userID: userID)
        loadCachedOverview(userID: userID)
        loadLocalCards(userID: userID)
        loadLibraryCards(userID: userID)
        reviewOutbox.activate(userID: userID)
        reviewRecordingService.activate(userID: userID)
        cardOutbox.activate(userID: userID)
        cardActionOutbox.activate(userID: userID)
        manualDraftOutbox.activate(userID: userID)
        manualDraftOutboxRevision &+= 1
        cardMediaService.activate(userID: userID)
        pitchAccentService.activate(userID: userID)
        sessionLoadingService.activate(userID: userID)
        syncCoordinator.activate(userID: userID)
        restorePendingReviewState()
        reloadFailedStudyChanges()
        knownKanjiService.activate(userID: userID)
        restoreCardCatalogSnapshot(userID: userID)
        offlineReserveMetadata = cardCatalogSnapshotCache?.loadOfflineReserveMetadata(
            userID: userID
        )
        activateOfflineDueCards(preservingCurrentOrder: false)
    }

    func deactivate() {
        persistPendingOverviewSnapshot()
        persistCardCatalogSnapshot()
        persistManualDraftSnapshot()
        accountActivationGeneration += 1
        studySettingsMutationRevision += 1
        studySettingsRefreshID = nil
        studySettingsUpdateID = nil
        overviewRefreshID = nil
        dueActivationScheduler.cancel()
        overviewSnapshotSaveTask?.cancel()
        overviewSnapshotSaveTask = nil
        overviewSnapshot = nil
        activeUserID = nil
        mediaCache.deactivate()
        knownKanjiService.deactivate()
        cardOutbox.deactivate()
        cardActionOutbox.deactivate()
        manualDraftOutbox.deactivate()
        manualDraftOutboxRevision &+= 1
        cardMediaService.deactivate()
        pitchAccentService.deactivate()
        sessionLoadingService.deactivate()
        syncCoordinator.deactivate()
        reviewRecordingService.deactivate()
        reviewOutbox.deactivate()
        cards = []
        libraryCards = []
        allCards = []
        allCardsNextCursor = nil
        allCardsQuery = ""
        pitchAccentResolutionTokens = [:]
        resolvingPitchAccentCardIDs = []
        allCardsRefreshRevision += 1
        isRefreshingAllCards = false
        isLoadingMoreAllCards = false
        learningItems = []
        learningItemsNextCursor = nil
        learningItemsQuery = ""
        learningItemsRefreshedAt = nil
        learningItemsLocalFallbackOffset = nil
        learningItemsLocalFallbackIdentifiers = nil
        learningItemsRefreshRevision += 1
        isRefreshingLearningItems = false
        isLoadingMoreLearningItems = false
        newCardQueue = []
        newCardQueueTotal = 0
        newCardQueueNextCursor = nil
        newCardQueueRefreshedAt = nil
        newCardQueueRefreshRevision += 1
        newCardQueueReorderToken = nil
        isRefreshingNewCardQueue = false
        isLoadingMoreNewCardQueue = false
        cardCatalogSnapshot = nil
        manualDraftsRefreshedAt = nil
        overview = nil
        offlineReserveMetadata = nil
        isRefreshingOverview = false
        overviewRefreshErrorMessage = nil
        studySettings = nil
        isUpdatingStudySettings = false
        studySettingsErrorMessage = nil
        failedStudyChanges = []
        newlyFailedCardIDs = []
        retainedFailedCardIDs = []
        resolvedFailedCardIDs = []
        sessionFailureWasPresentByEventID = [:]
        syncStatus = .idle
        lastSyncAt = nil
        lastSessionRefreshAt = nil
        outboxRetryRevision = 0
        consumedOutboxRetryRevision = 0
        failedStudyChangeOperationIDs = []
        cardActionCardIDs = []
        sessionInitialCardCount = 0
        sessionCompletedCardIDs = []
        sessionFailedCardIDs = []
        sessionKind = "reviews"
        studySurfaceRevision += 1
        lessonSessionIsPresented = false
        activeLessonPresentationID = nil
        activeLessonCohortID = nil
        masteryAnimation = nil
    }

    func persistCachedState() {
        persistPendingOverviewSnapshot()
        persistCardCatalogSnapshot()
        persistManualDraftSnapshot()
    }

    func deleteLocalData(userID: Int) throws {
        if activeUserID == userID {
            deactivate()
        }
        cardCatalogSnapshotCache?.remove(userID: userID)
        let cards = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        let mutations = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        let syncStates = try context.fetch(
            FetchDescriptor<LocalSyncState>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        let overviewSnapshots = try context.fetch(
            FetchDescriptor<LocalStudyOverviewSnapshot>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        try knownKanjiService.stageLocalDataDeletion(userID: userID)
        cards.forEach(context.delete)
        mutations.forEach(context.delete)
        syncStates.forEach(context.delete)
        overviewSnapshots.forEach(context.delete)
        try context.save()
    }

    func restoreCardCatalogSnapshot(userID: Int) {
        let snapshot = cardCatalogSnapshotCache?.load(userID: userID)
        cardCatalogSnapshot = snapshot
        if let snapshot {
            newCardQueue = snapshot.newCardQueue
            newCardQueueTotal = snapshot.newCardQueueTotal
            newCardQueueNextCursor = snapshot.newCardQueueNextCursor
            newCardQueueRefreshedAt = snapshot.newCardQueueRefreshedAt
            reconcilePendingCardMutationsIntoNewCardQueue()
            learningItems = snapshot.learningItems
            learningItemsNextCursor = snapshot.learningItemsNextCursor
            learningItemsRefreshedAt = snapshot.learningItemsRefreshedAt
            restoreLocalLearningItemFallbackCursor(snapshot.learningItemsNextCursor)
            reconcilePendingCardMutationsIntoLearningItems()
        } else {
            // Existing installations already have the full local card records in
            // SwiftData. Use them as the first-launch presentation until the richer
            // grouped catalog and authoritative queue snapshot arrive in the background.
            var seenCardIDs = Set<String>()
            let localNewCards = (cards + libraryCards).filter { card in
                card.state.queueState == "new"
                    && seenCardIDs.insert(card.id.lowercased()).inserted
            }
            newCardQueue = localNewCards.enumerated().map { offset, card in
                StudyNewCardQueueItem(
                    id: card.id,
                    noteId: card.noteId ?? card.id,
                    cardType: card.cardType,
                    displayText: card.promptText,
                    meaning: card.answerText,
                    queuePosition: offset + 1,
                    createdAt: card.createdAt,
                    updatedAt: card.updatedAt
                )
            }
            newCardQueueTotal = max(overview?.newCount ?? 0, newCardQueue.count)
            newCardQueueNextCursor = nil
            installLocalLearningItemFallback(matching: "")
        }

        if let manualDraftSnapshot = cardCatalogSnapshotCache?.loadManualDrafts(userID: userID) {
            manualDraftSnapshot.drafts.forEach(manualDraftOutbox.replace)
            manualDraftsRefreshedAt = manualDraftSnapshot.refreshedAt
        }
    }

    func persistCardCatalogSnapshot() {
        guard let userID = activeUserID, let cardCatalogSnapshotCache else { return }
        let defaultLearningItems: [StudyLearningItem]
        let defaultLearningItemsNextCursor: String?
        let defaultLearningItemsRefreshedAt: Date?
        if learningItemsQuery.isEmpty {
            defaultLearningItems = learningItems
            defaultLearningItemsNextCursor = learningItemsNextCursor
            defaultLearningItemsRefreshedAt = learningItemsRefreshedAt
        } else {
            defaultLearningItems = cardCatalogSnapshot?.learningItems ?? []
            defaultLearningItemsNextCursor = cardCatalogSnapshot?.learningItemsNextCursor
            defaultLearningItemsRefreshedAt = cardCatalogSnapshot?.learningItemsRefreshedAt
        }
        let snapshot = StudyCardCatalogSnapshot(
            savedAt: .now,
            newCardQueue: newCardQueue,
            newCardQueueTotal: newCardQueueTotal,
            newCardQueueNextCursor: newCardQueueNextCursor,
            newCardQueueRefreshedAt: newCardQueueRefreshedAt,
            learningItems: defaultLearningItems,
            learningItemsNextCursor: defaultLearningItemsNextCursor,
            learningItemsRefreshedAt: defaultLearningItemsRefreshedAt
        )
        cardCatalogSnapshot = snapshot
        cardCatalogSnapshotCache.save(snapshot, userID: userID)
    }

    func persistManualDraftSnapshot() {
        guard let userID = activeUserID, let cardCatalogSnapshotCache else { return }
        cardCatalogSnapshotCache.saveManualDrafts(
            StudyManualDraftSnapshot(
                savedAt: .now,
                drafts: manualDrafts,
                refreshedAt: manualDraftsRefreshedAt
            ),
            userID: userID
        )
    }

    func isFresh(_ refreshedAt: Date?, maxAge: TimeInterval) -> Bool {
        guard let refreshedAt else { return false }
        return Date.now.timeIntervalSince(refreshedAt) < max(0, maxAge)
    }

    var offlineReserveDays: Int? {
        offlineReserveMetadata?.reserveDays
    }

    var offlineReserveIsCurrent: Bool {
        offlineReserveMetadata.map { $0.horizonEndsAt > .now } ?? false
    }

    var reserveNewCardTarget: Int {
        guard offlineReserveIsCurrent else { return 0 }
        return (overview?.newCardsPerDay ?? 0) * max(0, offlineReserveMetadata?.reserveDays ?? 0)
    }

    var offlineReadinessTarget: Int {
        sessionCounts.offlineReadinessTarget(
            loadedCardCount: cards.count,
            reserveNewCardTarget: reserveNewCardTarget
        )
    }

    var sessionCounts: StudySessionCounts {
        StudySessionCounts.calculate(
            cards: cards,
            overview: overview,
            retainedFailedCardIDs: retainedFailedCardIDs,
            resolvedFailedCardIDs: resolvedFailedCardIDs
        )
    }

    private var nextOfflineDueAt: Date? {
        StudySessionPolicy.nextOfflineDueAt(
            activeCards: cards,
            libraryCards: libraryCards
        )
    }

    func localMediaURL(for remoteURL: URL) -> URL? {
        mediaCache.localURL(for: remoteURL)
    }

    func playableMediaURL(for remoteURL: URL) async -> URL? {
        if let localURL = localMediaURL(for: remoteURL) {
            return localURL
        }
        return try? await mediaCache.download(remoteURL, category: "active-study")
    }

    func resolvePitchAccent(for card: StudyCard) async {
        guard let userID = activeUserID else { return }
        let resolutionToken = UUID()
        guard
            card.answer["pitchAccent"]?["status"]?.stringValue == nil,
            pitchAccentResolutionTokens[card.id] == nil
        else {
            return
        }
        pitchAccentResolutionTokens[card.id] = resolutionToken
        resolvingPitchAccentCardIDs.insert(card.id)
        defer {
            let trackedIDs = pitchAccentResolutionTokens.compactMap { id, token in
                token == resolutionToken ? id : nil
            }
            for id in trackedIDs {
                pitchAccentResolutionTokens.removeValue(forKey: id)
                resolvingPitchAccentCardIDs.remove(id)
            }
        }

        do {
            guard let updatedCard = try await pitchAccentService.resolve(
                card,
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.flushCardOutbox()
                },
                onCardPrepared: { [weak self] preparedCard in
                    guard let self, self.activeUserID == userID else { return false }
                    if let existingToken = self.pitchAccentResolutionTokens[preparedCard.id] {
                        return existingToken == resolutionToken
                    }
                    self.pitchAccentResolutionTokens[preparedCard.id] = resolutionToken
                    self.resolvingPitchAccentCardIDs.insert(preparedCard.id)
                    return true
                },
                hasPendingDelete: { [weak self] resolvedCard in
                    guard let self else { throw CancellationError() }
                    return try self.cardOutbox.hasPendingDelete(for: resolvedCard)
                }
            ), activeUserID == userID else { return }
            let identifiers = StudyCardIdentity.identifiers(for: card).union(
                StudyCardIdentity.identifiers(for: updatedCard)
            )
            cards = cards.map {
                StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
            }
            libraryCards = libraryCards.map {
                StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
            }
            allCards = allCards.map {
                StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
            }
        } catch {
            // Pitch accent is optional enrichment. Offline and unresolved cards
            // remain fully studyable and can retry on a later reveal.
        }
    }

    var preparedCardCount: Int {
        guard let userID = activeUserID else { return 0 }
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate {
                $0.userID == userID && $0.mediaPreparedAt != nil
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func synchronize() async {
        await performSynchronization(requestingPromptRetryOnOutboxFailure: true)
    }

    private func performSynchronization(
        requestingPromptRetryOnOutboxFailure: Bool
    ) async {
        guard let userID = activeUserID, syncStatus != .syncing else { return }
        let diagnosticInterval = diagnostics.begin(.synchronization)
        var diagnosticOutcome: NativeDiagnosticOutcome = .cancelled
        defer {
            diagnostics.end(
                diagnosticInterval,
                outcome: diagnosticOutcome
            )
        }
        defer { reloadFailedStudyChanges() }
        let activationGeneration = accountActivationGeneration
        syncStatus = .syncing
        var firstError: (any Error)?
        var retryNeeded = false
        var refreshed = false
        var checkpointWasReset = false

        do {
            try await flushCardOutbox()
        } catch {
            firstError = error
            retryNeeded = retryNeeded || Self.requiresAutomaticRetry(error)
        }
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { return }
        do {
            try await retryPendingDraftMutations(
                userID: userID,
                activationGeneration: activationGeneration
            )
        } catch {
            firstError = firstError ?? error
            retryNeeded = retryNeeded || Self.requiresAutomaticRetry(error)
        }
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { return }
        do {
            try await flushSchedulingOutboxes()
        } catch {
            firstError = firstError ?? error
            retryNeeded = retryNeeded || Self.requiresAutomaticRetry(error)
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        do {
            let result = try await syncCoordinator.pullChanges(
                currentPublishedCards: publishedCards,
                publish: publish,
                reloadAfterCheckpointReset: {
                    if !self.lessonSessionIsPresented {
                        self.loadLocalCards(userID: userID)
                    }
                    self.loadLibraryCards(userID: userID)
                }
            )
            switch result {
            case .completed:
                break
            case .checkpointReset:
                checkpointWasReset = true
            case .discardedStaleResponse:
                diagnosticOutcome = .discarded
                return
            }
        } catch {
            firstError = firstError ?? error
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        // Fetch small, user-visible metadata before session media preparation
        // consumes the shared production request bucket.
        do {
            try await refreshKnownKanji()
        } catch {
            firstError = firstError ?? error
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        do {
            refreshed = try await refreshSessionPreservingActiveLessons()
        } catch {
            firstError = firstError ?? error
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        do {
            try await refreshOfflineReserve(
                userID: userID,
                activationGeneration: activationGeneration,
                clearingOtherRecords: checkpointWasReset || refreshed
            )
        } catch {
            firstError = firstError ?? error
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }

        let completedAt = Date.now
        if refreshed {
            lastSessionRefreshAt = completedAt
        }
        if retryNeeded, requestingPromptRetryOnOutboxFailure {
            outboxRetryRevision += 1
        }
        if let firstError {
            diagnosticOutcome = .failed
            handleSyncError(
                firstError,
                for: userID,
                activationGeneration: activationGeneration
            )
        } else {
            // This timestamp represents a successful end-to-end sync, not merely
            // a successful session refresh after another domain failed.
            if refreshed {
                lastSyncAt = completedAt
            }
            syncStatus = .idle
            diagnosticOutcome = .succeeded
        }
    }

    private func publishedCards() -> StudySyncCoordinator.PublishedCards {
        StudySyncCoordinator.PublishedCards(
            session: cards,
            library: libraryCards,
            catalog: allCards
        )
    }

    private func publish(_ published: StudySyncCoordinator.PublishedCards) {
        cards = published.session
        libraryCards = published.library
        allCards = published.catalog
    }

    func pullCardChangesForProgressionRevalidation(
        userID: Int,
        activationGeneration: Int
    ) async throws {
        let result = try await syncCoordinator.pullChanges(
            currentPublishedCards: publishedCards,
            publish: publish,
            reloadAfterCheckpointReset: {
                self.loadLocalCards(userID: userID)
                self.loadLibraryCards(userID: userID)
            }
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if result == .discardedStaleResponse { return }
        loadLibraryCards(userID: userID)
    }

    func synchronizeIfNeeded(maxAge: Duration) async {
        guard syncStatus != .syncing else { return }
        if consumedOutboxRetryRevision < outboxRetryRevision {
            // Give a failed mutation outbox one prompt retry. If that attempt
            // also fails, use session freshness to bound subsequent automatic
            // attempts until the normal max-age window expires. Consume only
            // the revision observed here so an interleaved eager failure is not
            // lost while this sync is suspended at a network await.
            consumedOutboxRetryRevision = outboxRetryRevision
            await performSynchronization(requestingPromptRetryOnOutboxFailure: false)
            return
        }
        let components = maxAge.components
        let maxAgeSeconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        if let lastSessionRefreshAt,
           Date.now.timeIntervalSince(lastSessionRefreshAt) < maxAgeSeconds
        {
            activateOfflineDueCards()
            return
        }
        await synchronize()
    }

    private func refreshOfflineReserve(
        userID: Int,
        activationGeneration: Int,
        clearingOtherRecords: Bool
    ) async throws {
        let reserve: StudyOfflineReserve = try await api.request(
            "/api/study/offline-reserve",
            method: "POST"
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        let preservingActiveReviewQueue = lessonSessionIsPresented
        let persistedActiveCards = preservingActiveReviewQueue
            ? try localCardRepository.activeCards(userID: userID)
            : []
        try localCardRepository.mergeOfflineReserve(
            reserve.cards,
            userID: userID,
            preservingActiveSessionOrder: preservingActiveReviewQueue
        )
        offlineReserveMetadata = reserve.metadata
        cardCatalogSnapshotCache?.saveOfflineReserveMetadata(reserve.metadata, userID: userID)
        loadLibraryCards(userID: userID)
        scheduleNextOfflineActivation()
        await mediaCache.prepare(
            urls: reserve.cards.flatMap(\.mediaURLs),
            category: "offline-study"
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        markPrepared(
            cards: cards + reserve.cards + persistedActiveCards,
            clearingOtherRecords: clearingOtherRecords
        )
    }

    func refreshKnownKanji() async throws {
        try await knownKanjiService.refresh()
    }

    func activateOfflineDueCards(
        at date: Date? = nil,
        preservingCurrentOrder: Bool = true
    ) {
        guard let userID = activeUserID, !lessonSessionIsPresented else { return }
        let activationDate = date ?? dueActivationScheduler.now
        let records = (try? context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && !$0.isInActiveSession
                },
                sortBy: [SortDescriptor(\.normalizedID), SortDescriptor(\.id)]
            )
        )) ?? []
        let pendingDeleteIDs = (try? cardOutbox.pendingDeleteIdentifiers()) ?? []
        var inactiveRecordsByIdentifier: [String: LocalCardRecord] = [:]
        for record in records {
            for identifier in [record.normalizedID, record.syncID]
            where !identifier.isEmpty && inactiveRecordsByIdentifier[identifier] == nil {
                inactiveRecordsByIdentifier[identifier] = record
            }
        }
        var activeCardIdentifiers = cards.reduce(into: Set<String>()) {
            $0.formUnion(StudyCardIdentity.identifiers(for: $1))
        }
        var newlyDueCards: [StudyCard] = []
        var changed = false

        for card in libraryCards {
            guard
                !StudyCardIdentity.matches(card, any: pendingDeleteIDs),
                card.isEligibleForOfflineStudy(at: activationDate)
            else {
                continue
            }
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if activeCardIdentifiers.isDisjoint(with: identifiers) {
                guard let record = identifiers.lazy.compactMap({
                    inactiveRecordsByIdentifier[$0]
                }).first else { continue }
                activeCardIdentifiers.formUnion(identifiers)
                newlyDueCards.append(card)
                changed = true
                record.isInActiveSession = true
            }
        }

        if changed {
            let orderedNewCards = StudySessionPolicy.offlineOrderedCards(newlyDueCards)
            cards = preservingCurrentOrder
                ? cards + orderedNewCards
                : StudySessionPolicy.offlineOrderedCards(cards + orderedNewCards)
            do {
                try context.save()
            } catch {
                handleSyncError(error)
            }
        }
        scheduleNextOfflineActivation()
    }

    func connectWaniKani(apiToken: String) async {
        await knownKanjiService.connect(apiToken: apiToken)
    }

    func syncWaniKani() async {
        await knownKanjiService.synchronize()
    }

    func disconnectWaniKani() async {
        await knownKanjiService.disconnect()
    }

    func setWaniKaniTransferBridgeEnabled(_ enabled: Bool) async {
        await knownKanjiService.setTransferBridgeEnabled(enabled)
    }

    func createCard(
        expression: String,
        reading: String,
        meaning: String
    ) async throws {
        var draft = StudyCardDraft(
            defaultAnswerAudioVoiceID: capabilities.cardAuthoring.defaultAnswerAudioVoiceId
        )
        draft.cueText = expression
        draft.cueReading = reading
        draft.answerExpression = expression
        draft.answerMeaning = meaning
        try await createCard(draft)
    }

    @discardableResult
    func createCard(_ draft: StudyCardDraft) async throws -> StudyCard {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let id = ClientIdentifier.ulid()
        let now = Date.now
        let projection = StudyCardEditorProjection.creating(draft, id: id, at: now)
        let optimistic = projection.card
        let cardData = try StorageCodec.encoder.encode(optimistic)
        let record = LocalCardRecord(
            card: optimistic,
            userID: userID,
            queueIndex: cards.count,
            payload: cardData
        )
        record.locallyUpdatedAt = now
        context.insert(record)
        try cardOutbox.stageCreate(cardID: id, request: projection.request)
        cards.append(optimistic)
        libraryCards.append(optimistic)
        upsertAllCardsPresentation(optimistic, addToLearningItemsIfMissing: true)
        try context.save()

        do {
            try await flushCardOutbox()
        } catch {
            markOutboxRetryNeeded(for: error)
            handleSyncError(
                error,
                for: userID,
                activationGeneration: activationGeneration
            )
        }
        return optimistic
    }

    func updateCard(
        _ card: StudyCard,
        prompt: String,
        reading: String,
        answer: String
    ) async throws {
        var draft = StudyCardDraft(
            card: card,
            defaultAnswerAudioVoiceID: capabilities.cardAuthoring.defaultAnswerAudioVoiceId
        )
        draft.cueText = prompt
        draft.cueReading = reading
        draft.answerExpression = prompt
        draft.answerMeaning = answer
        try await updateCard(card, draft: draft)
    }

    func updateCard(_ card: StudyCard, draft: StudyCardDraft) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let currentCard = try currentLocalCard(for: card)
        let projection = StudyCardEditorProjection.updating(
            currentCard,
            with: draft,
            at: .now
        )
        let updated = projection.card
        try updateExistingLocalCard(updated, markedDirty: true)
        try cardOutbox.stageUpdate(
            cardID: currentCard.id,
            request: projection.request
        )
        cards = cards.map { $0.id == currentCard.id ? updated : $0 }
        libraryCards = libraryCards.map { $0.id == currentCard.id ? updated : $0 }
        allCards = allCards.map { $0.id == currentCard.id ? updated : $0 }
        reconcileLearningItems(upserting: updated)
        reconcileCachedDefaultLearningItems(upserting: updated)
        reconcilePendingCardMutationsIntoNewCardQueue()
        try context.save()
        persistCardCatalogSnapshot()
        do {
            try await flushCardOutbox()
        } catch {
            markOutboxRetryNeeded(for: error)
            handleSyncError(
                error,
                for: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    func deleteCard(_ card: StudyCard) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let currentCard = try currentLocalCard(for: card)
        try cardOutbox.stageDelete(cardID: currentCard.id)
        let cardID = currentCard.id
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.id == cardID }
        )
        if let record = try context.fetch(descriptor).first {
            context.delete(record)
        }
        cards.removeAll { $0.id == currentCard.id }
        libraryCards.removeAll { $0.id == currentCard.id }
        allCards.removeAll { $0.id == currentCard.id }
        removeFromLearningItems(currentCard)
        removeFromCachedDefaultLearningItems(currentCard)
        reconcilePendingCardMutationsIntoNewCardQueue()
        try context.save()
        persistCardCatalogSnapshot()
        do {
            try await flushCardOutbox()
        } catch {
            markOutboxRetryNeeded(for: error)
            handleSyncError(
                error,
                for: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    @discardableResult
    func performCardAction(
        _ action: StudyCardActionName,
        on card: StudyCard,
        mode: StudyCardSetDueMode? = nil,
        dueAt: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) async throws -> StudyCard {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let actionKey = card.id.lowercased()
        guard cardActionCardIDs.insert(actionKey).inserted else {
            throw CardActionInProgressError()
        }
        defer { cardActionCardIDs.remove(actionKey) }
        let currentCard = try currentLocalCard(for: card)
        let prepared = try StudyCardActionProjection.prepare(
            action: action,
            card: currentCard,
            mode: mode,
            dueAt: dueAt,
            timeZone: timeZone,
            now: .now
        )
        try cardActionOutbox.stage(
            cardID: currentCard.reviewCardID,
            request: prepared.request
        )
        let currentIdentifiers = StudyCardIdentity.identifiers(for: currentCard)
        let wasInActiveSession = cards.contains {
            StudyCardIdentity.matches($0, any: currentIdentifiers)
        }
        try applyCardActionCard(
            prepared.card,
            serverCard: nil,
            overview: nil,
            wasInActiveSession: wasInActiveSession,
            preservingPendingEdit: try hasPendingCardWrite(for: currentCard),
            preservingPendingSchedule: true
        )

        do {
            // Preserve the original cross-domain ordering: content writes and
            // reviews staged before this action must be accepted first.
            try await flushCardOutbox()
            try await flushSchedulingOutboxes()
            guard isCurrentActivation(userID, generation: activationGeneration) else {
                throw CancellationError()
            }
            apply(try reviewOutbox.pendingState())
        } catch {
            markOutboxRetryNeeded(for: error)
            handleSyncError(
                error,
                for: userID,
                activationGeneration: activationGeneration
            )
        }
        return try currentLocalCard(for: prepared.card)
    }

    func regenerateAnswerAudio(
        for card: StudyCard,
        voiceID: String,
        textOverride: String
    ) async throws -> AnswerAudioRegenerationResult {
        try requirePersistentWrites()
        let currentCard = try await prepareCardMediaMutation(for: card, medium: "audio")
        return try await cardMediaService.regenerateAnswerAudio(
            currentCard: currentCard,
            voiceID: voiceID,
            textOverride: textOverride,
            latestCard: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.currentLocalCard(for: currentCard)
            },
            hasPendingWrite: { [weak self] cardID in
                guard let self else { throw CancellationError() }
                return try self.cardOutbox.hasPendingCardWrite(for: cardID)
            },
            onReconciled: { [weak self] card, pendingWrite, serverUpdatedAt in
                guard let self else { throw CancellationError() }
                try self.cardOutbox.trackRegeneratedAnswerAudio(
                    cardID: card.id,
                    prompt: card.prompt,
                    answer: card.answer
                )
                try self.reconcileCardMedia(
                    card,
                    pendingWrite: pendingWrite,
                    serverUpdatedAt: serverUpdatedAt
                )
            }
        )
    }

    func regenerateImage(
        for card: StudyCard,
        prompt: String,
        placement: StudyCardDraft.ImagePlacement
    ) async throws -> ImageRegenerationResult {
        try requirePersistentWrites()
        // Validate before the preflight flush so bad editor input cannot send an
        // unrelated queued card mutation. The service repeats this for direct callers.
        let imagePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumPromptCharacters = capabilities.cardAuthoring.limits.imagePromptCharacters
        guard
            !imagePrompt.isEmpty,
            imagePrompt.count <= maximumPromptCharacters
        else {
            throw InvalidCardImagePromptError(maximumCharacters: maximumPromptCharacters)
        }
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        let currentCard = try await prepareCardMediaMutation(for: card, medium: "image")
        return try await cardMediaService.regenerateImage(
            currentCard: currentCard,
            prompt: imagePrompt,
            placement: placement,
            maximumPromptCharacters: maximumPromptCharacters,
            latestCard: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.currentLocalCard(for: currentCard)
            },
            hasPendingWrite: { [weak self] cardID in
                guard let self else { throw CancellationError() }
                return try self.cardOutbox.hasPendingCardWrite(for: cardID)
            },
            onReconciled: { [weak self] card, pendingWrite, serverUpdatedAt in
                guard let self else { throw CancellationError() }
                try self.reconcileCardMedia(
                    card,
                    pendingWrite: pendingWrite,
                    serverUpdatedAt: serverUpdatedAt
                )
            }
        )
    }

    func uploadImage(
        for card: StudyCard,
        jpegData: Data,
        placement: StudyCardDraft.ImagePlacement
    ) async throws -> ImageRegenerationResult {
        try requirePersistentWrites()
        let maximumBytes = capabilities.cardAuthoring.limits.imageUploadBytes
        // As above, reject invalid editor state before the outbox preflight.
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        guard jpegData.count <= maximumBytes else {
            throw OversizedCardImageUploadError(maximumBytes: maximumBytes)
        }
        let currentCard = try await prepareCardMediaMutation(for: card, medium: "image")
        return try await cardMediaService.uploadImage(
            currentCard: currentCard,
            jpegData: jpegData,
            placement: placement,
            maximumBytes: maximumBytes,
            latestCard: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.currentLocalCard(for: currentCard)
            },
            hasPendingWrite: { [weak self] cardID in
                guard let self else { throw CancellationError() }
                return try self.cardOutbox.hasPendingCardWrite(for: cardID)
            },
            onReconciled: { [weak self] card, pendingWrite, serverUpdatedAt in
                guard let self else { throw CancellationError() }
                try self.reconcileCardMedia(
                    card,
                    pendingWrite: pendingWrite,
                    serverUpdatedAt: serverUpdatedAt
                )
            }
        )
    }

    private func prepareCardMediaMutation(
        for card: StudyCard,
        medium: String
    ) async throws -> StudyCard {
        do {
            try await flushCardOutbox()
        } catch is QuarantinedCardMutationError {
            // A rejected write for another card does not block this card.
        } catch {
            markOutboxRetryNeeded(for: error)
            throw error
        }
        let currentCard = try currentLocalCard(for: card)
        guard try !cardOutbox.hasPendingCardWrite(for: currentCard.id) else {
            throw PendingCardChangesError(medium: medium)
        }
        return currentCard
    }

    func prepareLearningPathAccess(for card: StudyCard) throws -> StudyCard {
        try requirePersistentWrites()
        let currentCard = try currentLocalCard(for: card)
        for identifier in Set([currentCard.id, currentCard.reviewCardID]) {
            guard try !cardOutbox.hasPendingCardWrite(for: identifier) else {
                throw PendingLearningPathChangesError()
            }
        }
        return currentCard
    }

    private func reconcileCardMedia(
        _ card: StudyCard,
        pendingWrite: Bool,
        serverUpdatedAt: Date
    ) throws {
        try updateExistingLocalCard(
            card,
            markedDirty: pendingWrite,
            serverUpdatedAt: serverUpdatedAt
        )
        cards = cards.map { $0.id == card.id ? card : $0 }
        libraryCards = libraryCards.map { $0.id == card.id ? card : $0 }
        allCards = allCards.map { $0.id == card.id ? card : $0 }
        try context.save()
    }

    var quarantinedMutationCount: Int {
        guard let userID = activeUserID else { return 0 }
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.userID == userID && $0.lastError != nil }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func fetchCanonicalCard(id: String) async throws -> StudyCard? {
        do {
            let response: StudyCardBatchResponse = try await api.request(
                "/api/study/cards/batch",
                method: "POST",
                body: StudyCardBatchRequest(ids: [id])
            )
            return response.cards.first
        } catch APIClientError.rejected(status: 404, message: _) {
            return nil
        }
    }

    func recoverCorruptedSchedulerState(
        for card: StudyCard,
        userID: Int,
        activationGeneration: Int
    ) async -> Bool {
        let identifiers = StudyCardIdentity.identifiers(for: card)
        do {
            guard try !cardOutbox.hasPendingCardWrite(for: card.id),
                  try !reviewOutbox.hasPendingReview(for: card.id)
            else {
                try removeFromActiveSession(card, userID: userID)
                return false
            }
            let canonicalCard = try await fetchCanonicalCard(id: card.reviewCardID)
            guard isCurrentActivation(userID, generation: activationGeneration) else {
                return false
            }
            // The fetch suspends this actor, so local work may have been staged
            // after the first guard. Re-check before replacing or deleting data.
            guard try !cardOutbox.hasPendingCardWrite(for: card.id),
                  try !reviewOutbox.hasPendingReview(for: card.id)
            else {
                try removeFromActiveSession(card, userID: userID)
                return false
            }
            guard let canonicalCard else {
                if let record = try localCardRepository.record(matching: card, userID: userID) {
                    context.delete(record)
                }
                cards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
                libraryCards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
                allCards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
                try context.save()
                return true
            }
            try updateExistingLocalCard(
                canonicalCard,
                markedDirty: false,
                serverUpdatedAt: canonicalCard.updatedAt
            )
            try context.save()
            // A repaired canonical record remains active so the user can retry
            // the grade that exposed the corruption.
            loadLocalCards(userID: userID)
            loadLibraryCards(userID: userID)
            return true
        } catch {
            guard isCurrentActivation(userID, generation: activationGeneration) else {
                return false
            }
            // Keep the replica for later reconciliation, but let the current
            // session advance past a card that cannot be graded safely.
            try? removeFromActiveSession(card, userID: userID)
            return false
        }
    }

    private func removeFromActiveSession(_ card: StudyCard, userID: Int) throws {
        if let record = try localCardRepository.record(matching: card, userID: userID) {
            record.isInActiveSession = false
        }
        let identifiers = StudyCardIdentity.identifiers(for: card)
        cards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
        try context.save()
    }

    func consumeOverviewCount(for card: StudyCard) {
        guard let current = overview else { return }
        setOverview(StudyOverview(
            dueCount: card.state.failedAt == nil && card.state.queueState != "new"
                ? max(0, current.dueCount - 1)
                : current.dueCount,
            newCount: card.state.queueState == "new"
                ? max(0, current.newCount - 1)
                : current.newCount,
            reviewCount: current.reviewCount,
            totalCards: current.totalCards,
            newCardsPerDay: current.newCardsPerDay,
            newCardsAvailableToday: card.state.queueState == "new"
                ? current.newCardsAvailableToday.map { max(0, $0 - 1) }
                : current.newCardsAvailableToday,
            failedCount: current.failedCount,
            // Pending-review state adjusts failedDueCount until the next authoritative
            // refresh. Mutating it here as well would decrement a failed card twice.
            failedDueCount: current.failedDueCount,
            lessonBatchSize: current.lessonBatchSize,
            reviewTimeBudgetMinutes: current.reviewTimeBudgetMinutes,
            masterySpread: current.masterySpread,
            jlptMastery: current.jlptMastery,
            learningReadiness: current.learningReadiness
        ), persistImmediately: false)
    }

    func dismissMasteryAnimation() {
        masteryAnimation = nil
    }

    func flushCardOutbox() async throws {
        guard let userID = activeUserID else { return }
        defer { reloadFailedStudyChanges() }
        let activeCardOrder = cards.map { $0.id.lowercased() }
        try await cardOutbox.flush(
            onDrainFinished: { [weak self] in
                guard let self, self.activeUserID == userID else { return }
                // Reconciliation can rename or remove records. Refresh once after
                // the drain while preserving an in-progress session's order.
                if !lessonSessionIsPresented {
                    loadLocalCards(
                        preservingNormalizedOrder: activeCardOrder,
                        userID: userID
                    )
                }
                loadLibraryCards(userID: userID)
            },
            onRevisionConflict: { [weak self] serverCard in
                guard let self, self.activeUserID == userID else {
                    throw CancellationError()
                }
                try applyCardRevisionConflict(serverCard)
            }
        ) { [weak self] acknowledgement in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            var acknowledgedCard = try acknowledgedCard(
                acknowledgement.card,
                preservingPendingReview: acknowledgement.preservingPendingReview,
                preservingPendingEdit: acknowledgement.preservingPendingEdit,
                submittedPromptAudio: acknowledgement.submittedPromptAudio,
                submittedAnswerAudioFields: acknowledgement.submittedAnswerAudioFields
            )
            let preservingPendingAction = try hasPendingCardAction(
                for: acknowledgedCard
            )
            if preservingPendingAction {
                let latestLocalCard = try currentLocalCard(for: acknowledgedCard)
                acknowledgedCard = StudyCard(
                    id: acknowledgedCard.id,
                    syncId: acknowledgedCard.syncId,
                    noteId: acknowledgedCard.noteId,
                    revision: acknowledgedCard.revision,
                    cardType: acknowledgedCard.cardType,
                    prompt: acknowledgedCard.prompt,
                    answer: acknowledgedCard.answer,
                    serverPresentation: acknowledgedCard.serverPresentation,
                    state: latestLocalCard.state,
                    answerAudioSource: acknowledgedCard.answerAudioSource,
                    masteryLevel: latestLocalCard.masteryLevel,
                    variantGroupId: acknowledgedCard.variantGroupId,
                    variantStatus: acknowledgedCard.variantStatus,
                    introductionCohortId: acknowledgedCard.introductionCohortId,
                    selectionPolicy: acknowledgedCard.selectionPolicy,
                    priorityUntil: acknowledgedCard.priorityUntil,
                    introductionAvailableAt: acknowledgedCard.introductionAvailableAt,
                    createdAt: acknowledgedCard.createdAt,
                    updatedAt: latestLocalCard.updatedAt
                )
            }
            try updateExistingLocalCard(
                acknowledgedCard,
                markedDirty: acknowledgement.preservingPendingEdit
                    || preservingPendingAction,
                serverUpdatedAt: acknowledgement.card.updatedAt,
                missingRecordError: MissingAcknowledgedCardError()
            )
        }
    }

    private func applyCardRevisionConflict(_ serverCard: StudyCard) throws {
        let preservingPendingReview = try hasPendingReview(for: serverCard)
        let preservingPendingAction = try hasPendingCardAction(for: serverCard)
        var authoritativeContent = try acknowledgedCard(
            serverCard,
            preservingPendingReview: preservingPendingReview,
            preservingPendingEdit: false
        )
        if preservingPendingAction {
            let latestLocalCard = try currentLocalCard(for: serverCard)
            authoritativeContent = StudyCard(
                id: authoritativeContent.id,
                syncId: authoritativeContent.syncId,
                noteId: authoritativeContent.noteId,
                revision: authoritativeContent.revision,
                cardType: authoritativeContent.cardType,
                prompt: authoritativeContent.prompt,
                answer: authoritativeContent.answer,
                serverPresentation: authoritativeContent.serverPresentation,
                state: latestLocalCard.state,
                answerAudioSource: authoritativeContent.answerAudioSource,
                masteryLevel: latestLocalCard.masteryLevel,
                variantGroupId: authoritativeContent.variantGroupId,
                variantStatus: authoritativeContent.variantStatus,
                introductionCohortId: authoritativeContent.introductionCohortId,
                selectionPolicy: authoritativeContent.selectionPolicy,
                priorityUntil: authoritativeContent.priorityUntil,
                introductionAvailableAt: authoritativeContent.introductionAvailableAt,
                createdAt: authoritativeContent.createdAt,
                updatedAt: latestLocalCard.updatedAt
            )
        }
        try updateExistingLocalCard(
            authoritativeContent,
            markedDirty: preservingPendingReview || preservingPendingAction,
            serverUpdatedAt: serverCard.updatedAt,
            missingRecordError: MissingAcknowledgedCardError()
        )
    }

    private func flushCardActionOutbox() async throws {
        guard let userID = activeUserID else { return }
        try await cardActionOutbox.flush { [weak self] acknowledgement in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            let response = acknowledgement.response
            let latestLocalCard = try currentLocalCard(for: response.card)
            let preservingPendingReview = try hasPendingReview(for: latestLocalCard)
            let preservingPendingEdit = try hasPendingCardWrite(for: latestLocalCard)
            var acknowledged = try acknowledgedCard(
                response.card,
                preservingPendingReview: preservingPendingReview,
                preservingPendingEdit: preservingPendingEdit
            )
            if acknowledgement.preservingNewerAction {
                acknowledged = StudyCard(
                    id: acknowledged.id,
                    syncId: acknowledged.syncId,
                    noteId: acknowledged.noteId,
                    revision: acknowledged.revision,
                    cardType: acknowledged.cardType,
                    prompt: acknowledged.prompt,
                    answer: acknowledged.answer,
                    serverPresentation: acknowledged.serverPresentation,
                    state: latestLocalCard.state,
                    answerAudioSource: acknowledged.answerAudioSource,
                    masteryLevel: latestLocalCard.masteryLevel,
                    variantGroupId: acknowledged.variantGroupId,
                    variantStatus: acknowledged.variantStatus,
                    introductionCohortId: acknowledged.introductionCohortId,
                    selectionPolicy: acknowledged.selectionPolicy,
                    priorityUntil: acknowledged.priorityUntil,
                    introductionAvailableAt: acknowledged.introductionAvailableAt,
                    createdAt: acknowledged.createdAt,
                    updatedAt: latestLocalCard.updatedAt
                )
            }
            let identifiers = StudyCardIdentity.identifiers(for: latestLocalCard)
            let wasInActiveSession = cards.contains {
                StudyCardIdentity.matches($0, any: identifiers)
            }
            try applyCardActionCard(
                acknowledged,
                serverCard: response.card,
                overview: acknowledgement.preservingNewerAction ? nil : response.overview,
                wasInActiveSession: wasInActiveSession,
                preservingPendingEdit: preservingPendingEdit,
                preservingPendingSchedule: preservingPendingReview
                    || acknowledgement.preservingNewerAction
            )
        }
    }

    @discardableResult
    func flushSchedulingOutboxes() async throws -> ReviewEventFlushResult {
        defer { reviewOutboxRevision &+= 1 }
        var result = try reviewOutbox.discardProgressionLockedFailures()
        do {
            while true {
                let before = try reviewOutbox.pendingDeliverableCount()
                    + cardActionOutbox.pendingDeliverableCount()
                guard before > 0 else { return result }

#if DEBUG
                if let reviewEventOutboxFlushOverride {
                    try await reviewEventOutboxFlushOverride()
                } else {
                    result.formUnion(try await reviewOutbox.flush())
                }
#else
                result.formUnion(try await reviewOutbox.flush())
#endif
                try await flushCardActionOutbox()

                let after = try reviewOutbox.pendingDeliverableCount()
                    + cardActionOutbox.pendingDeliverableCount()
                guard after > 0, after < before else { return result }
            }
        } catch let failure as ReviewEventFlushFailure {
            result.formUnion(failure.result)
            throw ReviewEventFlushFailure(
                result: result,
                underlyingError: failure.underlyingError
            )
        } catch {
            guard !result.isEmpty else { throw error }
            throw ReviewEventFlushFailure(result: result, underlyingError: error)
        }
    }

    private func applyCardActionCard(
        _ updatedCard: StudyCard,
        serverCard: StudyCard?,
        overview responseOverview: StudyOverview?,
        wasInActiveSession: Bool,
        preservingPendingEdit: Bool,
        preservingPendingSchedule: Bool
    ) throws {
        guard let userID = activeUserID else { throw CancellationError() }
        let updatedIdentifiers = StudyCardIdentity.identifiers(for: updatedCard)
        let staysInActiveSession = wasInActiveSession
            && !lessonSessionIsPresented
            && updatedCard.isEligibleForOfflineStudy(at: .now)

        try updateExistingLocalCard(
            updatedCard,
            markedDirty: preservingPendingEdit || preservingPendingSchedule,
            serverUpdatedAt: serverCard?.updatedAt
        )
        if let record = try localCardRepository.record(matching: updatedCard, userID: userID) {
            record.isInActiveSession = staysInActiveSession
        }

        if staysInActiveSession {
            cards = cards.map {
                StudyCardIdentity.matches($0, any: updatedIdentifiers) ? updatedCard : $0
            }
        } else {
            cards.removeAll { StudyCardIdentity.matches($0, any: updatedIdentifiers) }
            if wasInActiveSession {
                sessionCompletedCardIDs.insert(updatedCard.id)
            }
        }
        if let index = libraryCards.firstIndex(where: {
            StudyCardIdentity.matches($0, any: updatedIdentifiers)
        }) {
            libraryCards[index] = updatedCard
        } else {
            libraryCards.append(updatedCard)
        }
        upsertAllCardsPresentation(updatedCard)

        if let responseOverview {
            let reviewTimeBudgetMinutes = resolvedReviewTimeBudget(from: responseOverview)
            setOverview(responseOverview.updatingReviewTimeBudget(
                to: reviewTimeBudgetMinutes,
                fallbackJLPTMastery: overview?.jlptMastery
            ))
        }
        try context.save()
        scheduleNextOfflineActivation()
    }

    private func hasPendingReview(for card: StudyCard) throws -> Bool {
        try reviewOutbox.hasPendingReview(for: card.id)
            || (card.reviewCardID != card.id
                && reviewOutbox.hasPendingReview(for: card.reviewCardID))
    }

    private func hasPendingCardWrite(for card: StudyCard) throws -> Bool {
        try cardOutbox.hasPendingCardWrite(for: card.id)
            || (card.reviewCardID != card.id
                && cardOutbox.hasPendingCardWrite(for: card.reviewCardID))
    }

    private func hasPendingCardAction(for card: StudyCard) throws -> Bool {
        try cardActionOutbox.hasPendingAction(for: card.id)
            || (card.reviewCardID != card.id
                && cardActionOutbox.hasPendingAction(for: card.reviewCardID))
    }

    func restorePendingReviewState() {
        guard let state = try? reviewOutbox.pendingState() else { return }
        apply(state)
    }

    func apply(_ state: PendingReviewState) {
        newlyFailedCardIDs = state.newlyFailedCardIDs
        retainedFailedCardIDs = state.retainedFailedCardIDs
        resolvedFailedCardIDs = state.resolvedFailedCardIDs
    }

    @discardableResult
    func restoreReviewedCard(
        _ card: StudyCard,
        preservingLocalPresentation: Bool = false,
        presentationRevision: Int,
        undoingPresentedLesson: Bool
    ) throws -> StudyCard {
        guard try !cardOutbox.hasPendingDelete(for: card) else {
            throw DeletedCardUndoError()
        }
        let record = try localCardRecord(for: card)
        let restoredCard = restoredCard(
            card,
            matching: record,
            preservingLocalPresentation: preservingLocalPresentation
        )
        let normalizedID = restoredCard.id.lowercased()
        let presentationIsCurrent = presentationRevision == studySurfaceRevision

        if presentationIsCurrent {
            masteryAnimation = nil
            sessionCompletedCardIDs = Set(
                sessionCompletedCardIDs.filter { $0.lowercased() != normalizedID }
            )
            cards.removeAll { $0.id.lowercased() == normalizedID }
            cards.insert(restoredCard, at: 0)
        }
        if let index = libraryCards.firstIndex(
            where: { $0.id.lowercased() == normalizedID }
        ) {
            libraryCards[index] = restoredCard
        } else {
            libraryCards.append(restoredCard)
        }
        upsertAllCardsPresentation(restoredCard)

        let payload = try StorageCodec.encoder.encode(restoredCard)
        let belongsToActiveReviewSession = !undoingPresentedLesson
        if let record {
            let wasLocallyUpdated = record.locallyUpdatedAt != nil
            record.replacePayload(encoded: payload)
            // A newer surface owns durable membership. The completed undo is still
            // authoritative card data, but it must not overwrite membership chosen
            // by a refresh, checkpoint rebuild, or lesson transition.
            if presentationIsCurrent {
                record.isInActiveSession = belongsToActiveReviewSession
            }
            if !wasLocallyUpdated {
                record.serverUpdatedAt = restoredCard.updatedAt
            }
        } else {
            guard let userID = activeUserID else { throw CancellationError() }
            let newRecord = LocalCardRecord(
                card: restoredCard,
                userID: userID,
                queueIndex: 0,
                payload: payload
            )
            newRecord.isInActiveSession = presentationIsCurrent
                && belongsToActiveReviewSession
            context.insert(newRecord)
        }
        guard let userID = activeUserID else { throw CancellationError() }
        if presentationIsCurrent && belongsToActiveReviewSession {
            try localCardRepository.replaceActiveSession(with: cards, userID: userID)
        } else {
            try context.save()
        }
        scheduleNextOfflineActivation()
        return restoredCard
    }

    private func restoredCard(
        _ card: StudyCard,
        matching record: LocalCardRecord?,
        preservingLocalPresentation: Bool
    ) -> StudyCard {
        guard let record else { return card }
        let localCard = try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        let card = localCard.map {
            card.resolvingProgressionMetadata(fallingBackTo: $0)
        } ?? card
        let preserveLocalPresentation = preservingLocalPresentation
            || record.locallyUpdatedAt != nil
        guard record.id != card.id || preserveLocalPresentation else {
            return card
        }
        let restoredServerPresentation: StudyCardPresentationV1?
        if preserveLocalPresentation, let localCard {
            restoredServerPresentation = localCard.serverPresentation
        } else {
            restoredServerPresentation = card.serverPresentation
        }

        return StudyCard(
            id: record.id,
            syncId: card.syncId ?? localCard?.syncId,
            noteId: card.noteId,
            revision: preserveLocalPresentation
                ? localCard?.revision ?? card.revision
                : card.revision,
            cardType: preserveLocalPresentation
                ? localCard?.cardType ?? card.cardType
                : card.cardType,
            prompt: preserveLocalPresentation
                ? localCard?.prompt ?? card.prompt
                : card.prompt,
            answer: preserveLocalPresentation
                ? localCard?.answer ?? card.answer
                : card.answer,
            serverPresentation: restoredServerPresentation,
            state: card.state,
            answerAudioSource: preserveLocalPresentation
                ? localCard?.answerAudioSource ?? card.answerAudioSource
                : card.answerAudioSource,
            // Scheduling state and mastery come from the undo result; neither is editor-owned.
            masteryLevel: card.masteryLevel,
            variantGroupId: card.variantGroupId,
            variantStatus: card.variantStatus,
            introductionCohortId: card.introductionCohortId,
            selectionPolicy: card.selectionPolicy,
            priorityUntil: card.priorityUntil,
            introductionAvailableAt: card.introductionAvailableAt,
            createdAt: preserveLocalPresentation
                ? localCard?.createdAt ?? card.createdAt
                : card.createdAt,
            updatedAt: preserveLocalPresentation
                ? localCard?.updatedAt ?? card.updatedAt
                : card.updatedAt
        )
    }

    func markPrepared(cards: [StudyCard], clearingOtherRecords: Bool = false) {
        guard let userID = activeUserID else { return }
        let cachedKeys = mediaCache.cachedKeys(for: cards.flatMap(\.mediaURLs))
        try? localCardRepository.updateMediaPreparedState(
            for: cards,
            userID: userID,
            cachedKeys: cachedKeys,
            clearingOtherRecords: clearingOtherRecords
        )
    }

    private func acknowledgedCard(
        _ serverCard: StudyCard,
        preservingPendingReview: Bool,
        preservingPendingEdit: Bool,
        submittedPromptAudio: JSONValue? = nil,
        submittedAnswerAudioFields: [String: JSONValue]? = nil
    ) throws -> StudyCard {
        guard
            preservingPendingReview
                || preservingPendingEdit
                || submittedPromptAudio != nil
                || submittedAnswerAudioFields != nil
                || !serverCard.includesProgressionMetadataProjection
        else {
            return serverCard
        }
        guard let userID = activeUserID else { return serverCard }

        guard
            let record = try localCardRepository.record(matching: serverCard, userID: userID),
            let localCard = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            )
        else {
            return serverCard
        }
        let serverCard = serverCard.resolvingProgressionMetadata(
            fallingBackTo: localCard
        )

        // Compatibility PATCH responses can contain the pre-regeneration audio
        // projection. Reconcile the exact audio, voice, and override values that
        // regeneration wrote atomically and the accepted update request submitted.
        let answerAudioResponseWasStale = submittedAnswerAudioFields.map { fields in
            fields.contains { key, value in serverCard.answer[key] != value }
        } ?? false
        let answer: JSONValue
        if preservingPendingEdit {
            answer = localCard.answer
        } else if let submittedAnswerAudioFields {
            answer = serverCard.answer.replacingObjectValues(submittedAnswerAudioFields)
        } else {
            answer = serverCard.answer
        }
        let prompt: JSONValue
        if preservingPendingEdit {
            prompt = localCard.prompt
        } else if let submittedPromptAudio {
            prompt = serverCard.prompt.replacingObjectValues([
                "cueAudio": submittedPromptAudio,
            ])
        } else {
            prompt = serverCard.prompt
        }
        return StudyCard(
            id: record.id,
            // Keep the persisted local key while carrying the server-resolved identity as its alias.
            syncId: record.id == serverCard.id
                ? serverCard.syncId ?? localCard.syncId
                : serverCard.reviewCardID,
            noteId: serverCard.noteId,
            revision: preservingPendingEdit ? localCard.revision : serverCard.revision,
            cardType: serverCard.cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: prompt == serverCard.prompt && answer == serverCard.answer
                ? serverCard.serverPresentation
                : nil,
            state: preservingPendingReview ? localCard.state : serverCard.state,
            answerAudioSource: preservingPendingEdit || answerAudioResponseWasStale
                ? localCard.answerAudioSource
                : serverCard.answerAudioSource,
            // Current PATCH responses return computed, non-null mastery; legacy lean
            // responses may omit it. Editor input cannot clear mastery. If that contract
            // gains explicit clears, decoding must distinguish null from omission.
            masteryLevel: preservingPendingReview
                ? localCard.masteryLevel
                : serverCard.masteryLevel ?? localCard.masteryLevel,
            variantGroupId: serverCard.variantGroupId,
            variantStatus: serverCard.variantStatus,
            introductionCohortId: serverCard.introductionCohortId,
            selectionPolicy: serverCard.selectionPolicy,
            priorityUntil: serverCard.priorityUntil,
            introductionAvailableAt: serverCard.introductionAvailableAt,
            createdAt: serverCard.createdAt,
            updatedAt: preservingPendingReview || preservingPendingEdit
                ? localCard.updatedAt
                : serverCard.updatedAt
        )
    }

    private func currentLocalCard(for card: StudyCard) throws -> StudyCard {
        guard let currentCard = try currentLocalCardIfPresent(for: card) else {
            throw MissingLocalCardError()
        }
        return currentCard
    }

    func currentLocalCardIfPresent(for card: StudyCard) throws -> StudyCard? {
        guard let record = try localCardRecord(for: card) else { return nil }
        return try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    private func localCardRecord(for card: StudyCard) throws -> LocalCardRecord? {
        guard let userID = activeUserID else { return nil }
        return try localCardRepository.record(matching: card, userID: userID)
    }

    private func updateExistingLocalCard(
        _ card: StudyCard,
        markedDirty: Bool,
        serverUpdatedAt: Date? = nil,
        missingRecordError: any Error = MissingLocalCardError()
    ) throws {
        guard let userID = activeUserID else { throw CancellationError() }
        guard let record = try localCardRepository.record(matching: card, userID: userID) else {
            throw missingRecordError
        }
        try updateLocalCardRecord(
            record,
            with: card,
            markedDirty: markedDirty,
            serverUpdatedAt: serverUpdatedAt
        )
    }

    func upsertLocalCard(
        _ card: StudyCard,
        markedDirty: Bool,
        serverUpdatedAt: Date? = nil
    ) throws {
        guard let userID = activeUserID else { throw CancellationError() }
        if let record = try localCardRepository.record(matching: card, userID: userID) {
            try updateLocalCardRecord(
                record,
                with: card,
                markedDirty: markedDirty,
                serverUpdatedAt: serverUpdatedAt
            )
            return
        }

        let payload = try StorageCodec.encoder.encode(card)
        let record = LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: cards.count,
            payload: payload
        )
        record.serverUpdatedAt = serverUpdatedAt ?? card.updatedAt
        record.locallyUpdatedAt = markedDirty ? .now : nil
        context.insert(record)
    }

    private func updateLocalCardRecord(
        _ record: LocalCardRecord,
        with card: StudyCard,
        markedDirty: Bool,
        serverUpdatedAt: Date?
    ) throws {
        // Keep the persisted local key while carrying the resolved request identity as its alias.
        let persistedCard = record.id == card.id
            ? card
            : card.replacingIdentity(id: record.id, syncId: card.reviewCardID)
        record.replacePayload(encoded: try StorageCodec.encoder.encode(persistedCard))
        record.serverUpdatedAt = serverUpdatedAt ?? card.updatedAt
        record.locallyUpdatedAt = markedDirty ? .now : nil
    }

    func loadLocalCards(userID: Int) {
        studySurfaceRevision += 1
        cards = (try? localCardRepository.activeCards(userID: userID)) ?? []
        cards = StudySessionPolicy.offlineOrderedCards(cards)
    }

    private func loadLocalCards(
        preservingNormalizedOrder order: [String],
        userID: Int
    ) {
        studySurfaceRevision += 1
        var persistedByNormalizedID = Dictionary(
            ((try? localCardRepository.activeCards(userID: userID)) ?? [])
                .map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let preserved = order.compactMap { persistedByNormalizedID.removeValue(forKey: $0) }
        cards = preserved + StudySessionPolicy.offlineOrderedCards(
            Array(persistedByNormalizedID.values)
        )
    }

    func loadLibraryCards(userID: Int) {
        libraryCards = (try? localCardRepository.libraryCards(userID: userID)) ?? []
    }

    func scheduleNextOfflineActivation() {
        dueActivationScheduler.cancel()
        guard !lessonSessionIsPresented, let dueAt = nextOfflineDueAt else {
            return
        }
        dueActivationScheduler.schedule(at: dueAt) { [weak self, dueActivationScheduler] in
            self?.activateOfflineDueCards(at: dueActivationScheduler.now)
        }
    }

    private func handleSyncError(_ error: any Error) {
        let classifiedError = Self.underlyingReviewFlushError(error)
        if let urlError = classifiedError as? URLError, [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
        ].contains(urlError.code) {
            syncStatus = .offline
        } else {
            syncStatus = .failed(classifiedError.localizedDescription)
        }
    }

    static func requiresAutomaticRetry(_ error: any Error) -> Bool {
        let classifiedError = underlyingReviewFlushError(error)
        return !(classifiedError is QuarantinedCardMutationError
            || classifiedError is QuarantinedCardActionError
            || classifiedError is QuarantinedReviewError
            || classifiedError is FSRSReviewScheduler.InvalidSchedulerTimestampError)
    }

    private static func underlyingReviewFlushError(_ error: any Error) -> any Error {
        (error as? ReviewEventFlushFailure)?.underlyingError ?? error
    }

    func markOutboxRetryNeeded(for error: any Error) {
        if Self.requiresAutomaticRetry(error) {
            outboxRetryRevision += 1
        }
    }

    func requirePersistentWrites() throws {
        guard storageMode == .persistent else {
            throw StorageWriteUnavailableError(domain: .study)
        }
    }

    func handleSyncError(
        _ error: any Error,
        for userID: Int,
        activationGeneration: Int
    ) {
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        handleSyncError(error)
    }

    func isCurrentActivation(_ userID: Int, generation: Int) -> Bool {
        activeUserID == userID && accountActivationGeneration == generation
    }
}

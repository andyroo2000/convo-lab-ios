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

    private struct DeletedCardUndoError: LocalizedError {
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

    private struct PendingLearningPathChangesError: LocalizedError {
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

    private let api: APIClient
    private let context: ModelContext
    private let overviewContext: ModelContext
    private let mediaCache: MediaCache
    private let knownKanjiService: KnownKanjiService
    private let reviewOutbox: ReviewEventOutbox
    private let reviewRecordingService: StudyReviewRecordingService
    private let cardOutbox: CardMutationOutbox
    private let cardActionOutbox: CardActionOutbox
    private let manualDraftOutbox: ManualDraftOutbox
    private let cardMediaService: CardMediaMutationService
    private let pitchAccentService: PitchAccentResolutionService
    private let sessionLoadingService: StudySessionLoadingService
    private let syncCoordinator: StudySyncCoordinator
    private let localCardRepository: StudyCardLocalRepository
    private let cardCatalogRepository: StudyCardCatalogRepository
    private let learningPathRepository: StudyLearningPathRepository
    private let dueActivationScheduler: any StudyDueActivationScheduling
    private let reviewEventOutboxFlushOverride: (() async throws -> Void)?
    private let deviceID: String
    private let storageMode: StorageMode
    @ObservationIgnored private var allCardsRefreshRevision = 0
    @ObservationIgnored private var learningItemsRefreshRevision = 0
    @ObservationIgnored private var newCardQueueRefreshRevision = 0
    @ObservationIgnored private var newCardQueueReorderToken: UUID?
    @ObservationIgnored private var pitchAccentResolutionTokens: [String: UUID] = [:]
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var accountActivationGeneration = 0
    @ObservationIgnored private var studySettingsMutationRevision = 0
    @ObservationIgnored private var studySettingsRefreshID: UUID?
    @ObservationIgnored private var studySettingsUpdateID: UUID?
    @ObservationIgnored private var overviewRefreshID: UUID?
    @ObservationIgnored private var newlyFailedCardIDs: Set<String> = []
    @ObservationIgnored private var retainedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var resolvedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var sessionFailureWasPresentByEventID: [String: Bool] = [:]
    @ObservationIgnored private var overviewSnapshot: LocalStudyOverviewSnapshot?
    @ObservationIgnored private var overviewSnapshotSaveTask: Task<Void, Never>?
    @ObservationIgnored private var studySurfaceRevision = 0
    // Session freshness suppresses redundant UI refreshes. A failed mutation
    // outbox receives one prompt retry before returning to that throttle; the
    // read-only refresh domains use the ordinary max-age cadence.
    @ObservationIgnored private var lastSessionRefreshAt: Date?
    @ObservationIgnored private var outboxRetryRevision = 0
    @ObservationIgnored private var consumedOutboxRetryRevision = 0
    @ObservationIgnored private var failedStudyChangeOperationIDs: Set<String> = []
    @ObservationIgnored private var cardActionCardIDs: Set<String> = []

    private(set) var cards: [StudyCard] = []
    private(set) var libraryCards: [StudyCard] = []
    private(set) var allCards: [StudyCard] = []
    private(set) var allCardsNextCursor: String?
    private(set) var allCardsQuery = ""
    private(set) var isRefreshingAllCards = false
    private(set) var isLoadingMoreAllCards = false
    private(set) var learningItems: [StudyLearningItem] = []
    private(set) var learningItemsNextCursor: String?
    private(set) var learningItemsQuery = ""
    private(set) var isRefreshingLearningItems = false
    private(set) var isLoadingMoreLearningItems = false
    private(set) var newCardQueue: [StudyNewCardQueueItem] = []
    private(set) var newCardQueueTotal = 0
    private(set) var newCardQueueNextCursor: String?
    private(set) var isRefreshingNewCardQueue = false
    private(set) var isLoadingMoreNewCardQueue = false
    private(set) var storageWriteErrorMessage: String?
    private(set) var failedStudyChanges: [FailedStudyChange] = []
    var manualDrafts: [StudyManualCardDraft] { manualDraftOutbox.drafts }
    var pendingManualDraftCreates: [CreateStudyManualCardDraftRequest] {
        manualDraftOutbox.pendingCreateRequests()
    }
    private(set) var overview: StudyOverview?
    private(set) var isRefreshingOverview = false
    private(set) var overviewRefreshErrorMessage: String?
    private(set) var studySettings: StudySettings?
    private(set) var isUpdatingStudySettings = false
    private(set) var studySettingsErrorMessage: String?
    var knownKanji: Set<Character> { knownKanjiService.knownKanji }
    var manualKnownKanji: Set<Character> { knownKanjiService.manualKnownKanji }
    var knownKanjiVersion: Int { knownKanjiService.version }
    var wanikaniConnected: Bool { knownKanjiService.wanikaniConnected }
    var wanikaniLastSyncedAt: Date? { knownKanjiService.wanikaniLastSyncedAt }
    var wanikaniReviewCount: Int? { knownKanjiService.wanikaniReviewCount }
    var wanikaniReviewCountUpdatedAt: Date? {
        knownKanjiService.wanikaniReviewCountUpdatedAt
    }
    var isWaniKaniWorking: Bool { knownKanjiService.isWorking }
    var wanikaniErrorMessage: String? { knownKanjiService.errorMessage }
    private(set) var resolvingPitchAccentCardIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncAt: Date?
    private(set) var sessionInitialCardCount = 0
    private(set) var sessionCompletedCardIDs: Set<String> = []
    private(set) var sessionFailedCardIDs: Set<String> = []
    private(set) var sessionKind = "reviews"
    private(set) var pendingOfflineReviewCount = 0
    private var lessonSessionIsPresented = false
    private(set) var masteryAnimation: (
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

    private func refreshPendingOfflineReviewCount() {
        guard let activeUserID else {
            pendingOfflineReviewCount = 0
            return
        }
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == activeUserID
                    && $0.kind == "review"
                    && $0.lastError == nil
            }
        )
        pendingOfflineReviewCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    func beginLessonSessionPresentation() {
        guard !lessonSessionIsPresented else { return }
        studySurfaceRevision += 1
        lessonSessionIsPresented = true
        sessionLoadingService.invalidate()
        dueActivationScheduler.cancel()
        cards = []
        sessionInitialCardCount = 0
        sessionCompletedCardIDs = []
        masteryAnimation = nil
    }

    func endLessonSessionPresentation() {
        guard lessonSessionIsPresented else { return }
        studySurfaceRevision += 1
        lessonSessionIsPresented = false
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
        dueActivationScheduler: any StudyDueActivationScheduling = RunLoopStudyDueActivationScheduler(),
        reviewProjection: @escaping (
            StudyCard,
            ReviewRating,
            Date
        ) throws -> StudyCard = { card, rating, reviewedAt in
            try card.applyingReview(rating, at: reviewedAt)
        },
        reviewEventOutboxFlushOverride: (() async throws -> Void)? = nil
    ) {
        self.api = api
        self.context = context
        overviewContext = ModelContext(context.container)
        overviewContext.autosaveEnabled = false
        self.mediaCache = mediaCache
        self.storageMode = storageMode
        self.dueActivationScheduler = dueActivationScheduler
        self.reviewEventOutboxFlushOverride = reviewEventOutboxFlushOverride
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
        cardMediaService.activate(userID: userID)
        pitchAccentService.activate(userID: userID)
        sessionLoadingService.activate(userID: userID)
        syncCoordinator.activate(userID: userID)
        restorePendingReviewState()
        refreshPendingOfflineReviewCount()
        reloadFailedStudyChanges()
        knownKanjiService.activate(userID: userID)
        activateOfflineDueCards(preservingCurrentOrder: false)
    }

    func deactivate() {
        persistPendingOverviewSnapshot()
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
        learningItemsRefreshRevision += 1
        isRefreshingLearningItems = false
        isLoadingMoreLearningItems = false
        newCardQueue = []
        newCardQueueTotal = 0
        newCardQueueNextCursor = nil
        newCardQueueRefreshRevision += 1
        newCardQueueReorderToken = nil
        isRefreshingNewCardQueue = false
        isLoadingMoreNewCardQueue = false
        overview = nil
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
        pendingOfflineReviewCount = 0
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
        masteryAnimation = nil
    }

    func persistCachedState() {
        persistPendingOverviewSnapshot()
    }

    func deleteLocalData(userID: Int) throws {
        if activeUserID == userID {
            deactivate()
        }
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

    var fiveDayNewCardTarget: Int {
        (overview?.newCardsPerDay ?? 0) * 5
    }

    var offlineReadinessTarget: Int {
        sessionCounts.offlineReadinessTarget(
            loadedCardCount: cards.count,
            fiveDayNewCardTarget: fiveDayNewCardTarget
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
        defer {
            refreshPendingOfflineReviewCount()
            reloadFailedStudyChanges()
        }
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

    func loadNextReviewBatch() async {
        guard let userID = activeUserID, sessionKind == "reviews", cards.isEmpty else {
            return
        }

        // The offline reserve may already contain cards that became due after the
        // previous batch was loaded. Promote that delta before doing a full sync;
        // otherwise refreshSession can replace the active markers before these
        // locally ready cards ever reach the player.
        loadLibraryCards(userID: userID)
        activateOfflineDueCards()
        if cards.isEmpty {
            await synchronize()
            guard activeUserID == userID else { return }
            activateOfflineDueCards()
        }

        guard activeUserID == userID, !cards.isEmpty else { return }
        sessionInitialCardCount = cards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
    }

    @discardableResult
    func refreshSession() async throws -> Bool {
        guard let load = try await sessionLoadingService.load(.reviews) else { return false }
        let userID = load.userID
        let session = load.response.session
        let pendingReviewState = try reviewOutbox.pendingState()
        let activeCards = StudySessionPolicy.orderedCards(
            try eligibleSessionCards(
                from: session.cards,
                pendingReviewState: pendingReviewState
            )
        )
        let resolvedSettings = StudySettingsPolicy.settings(
            from: session.overview,
            fallbackReviewTimeBudget: resolvedReviewTimeBudget()
        )
        setOverview(StudySettingsPolicy.applying(
            resolvedSettings,
            to: session.overview,
            preservingJLPTMasteryFrom: overview
        ))
        studySettings = resolvedSettings
        studySurfaceRevision += 1
        cards = activeCards
        sessionKind = "reviews"
        sessionInitialCardCount = activeCards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        apply(pendingReviewState)
        try localCardRepository.replaceActiveSession(with: activeCards, userID: userID)
        loadLibraryCards(userID: userID)
        scheduleNextOfflineActivation()

        let mediaURLs = activeCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-study")
        if sessionLoadingService.isCurrent(load) {
            markPrepared(cards: activeCards)
        }
        return true
    }

    func refreshOverview() async {
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        let settingsMutationRevision = studySettingsMutationRevision
        let refreshID = UUID()
        overviewRefreshID = refreshID
        isRefreshingOverview = true
        overviewRefreshErrorMessage = nil

        defer {
            if isCurrentActivation(userID, generation: activationGeneration),
               overviewRefreshID == refreshID {
                isRefreshingOverview = false
            }
        }

        do {
            let refreshed: StudyOverview = try await api.request("/api/study/overview")
            guard isCurrentActivation(userID, generation: activationGeneration),
                  overviewRefreshID == refreshID else { return }
            let responseSettings = StudySettingsPolicy.settings(
                from: refreshed,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            let canPublishResponseSettings = studySettingsMutationRevision
                == settingsMutationRevision
            let appliedSettings = canPublishResponseSettings
                ? responseSettings
                : studySettings ?? responseSettings
            setOverview(StudySettingsPolicy.applying(
                appliedSettings,
                to: refreshed,
                preservingJLPTMasteryFrom: overview
            ))
            if canPublishResponseSettings {
                studySettings = responseSettings
            }
        } catch {
            guard isCurrentActivation(userID, generation: activationGeneration),
                  overviewRefreshID == refreshID else { return }
            overviewRefreshErrorMessage = error.localizedDescription
        }
    }

    /// A foreground sync must not replace a frozen lesson batch with review cards.
    /// The lesson remains stable until the user finishes it or explicitly leaves it.
    func refreshSessionPreservingActiveLessons() async throws -> Bool {
        guard !lessonSessionIsPresented else { return false }
        return try await refreshSession()
    }

    @discardableResult
    func refreshLessons() async throws -> Bool {
        guard let load = try await sessionLoadingService.load(.lessons) else { return false }
        let userID = load.userID
        let session = load.response.session
        let pendingReviewState = try reviewOutbox.pendingState()
        let eligibleLessonCards = try eligibleSessionCards(
            from: session.cards,
            pendingReviewState: pendingReviewState
        )
        let lessonBatchSize = min(max(session.overview.lessonBatchSize, 3), 10)
        let lessonCards = Array(eligibleLessonCards.prefix(lessonBatchSize))
        let resolvedSettings = StudySettingsPolicy.settings(
            from: session.overview,
            fallbackReviewTimeBudget: resolvedReviewTimeBudget()
        )
        setOverview(StudySettingsPolicy.applying(
            resolvedSettings,
            to: session.overview,
            preservingJLPTMasteryFrom: overview
        ))
        studySettings = resolvedSettings
        studySurfaceRevision += 1
        cards = lessonCards
        sessionKind = "lessons"
        sessionInitialCardCount = lessonCards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        if lessonSessionIsPresented {
            // Keep the review queue durable while its presentation is suspended.
            // Lesson cards are cached locally without taking over active-review flags.
            try localCardRepository.mergeOfflineReserve(
                lessonCards,
                userID: userID,
                preservingActiveSessionOrder: true
            )
        } else {
            try localCardRepository.replaceActiveSession(with: lessonCards, userID: userID)
        }
        loadLibraryCards(userID: userID)
        let mediaURLs = lessonCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-lesson")
        if sessionLoadingService.isCurrent(load) {
            markPrepared(cards: lessonCards)
        }
        return true
    }

    private func eligibleSessionCards(
        from candidates: [StudyCard],
        pendingReviewState: PendingReviewState
    ) throws -> [StudyCard] {
        guard activeUserID != nil else { return [] }
        let pendingDeleteIdentifiers = try cardOutbox.pendingDeleteIdentifiers()
        let pendingActionIdentifiers = try cardActionOutbox.pendingIdentifiers()
        let candidatesWithoutPendingDeletes = try candidates.compactMap { card -> StudyCard? in
            guard !StudyCardIdentity.matches(card, any: pendingDeleteIdentifiers) else {
                return nil
            }
            guard StudyCardIdentity.matches(card, any: pendingActionIdentifiers) else {
                return card
            }
            // A server session fetched while an action is queued must not replace
            // the durable optimistic schedule with the older server snapshot.
            return try currentLocalCardIfPresent(for: card) ?? card
        }
        return StudySessionPolicy.eligibleCards(
            from: candidatesWithoutPendingDeletes,
            excluding: pendingReviewState.cardIDs
        )
    }

    func retryLessonCard(_ card: StudyCard) {
        guard sessionKind == "lessons",
              let index = cards.firstIndex(where: {
                  StudyCardIdentity.matches($0, card)
              })
        else {
            return
        }
        let retryCard = cards.remove(at: index)
        cards.append(retryCard)
    }

    func refreshStudySettings() async {
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        let mutationRevision = studySettingsMutationRevision
        let refreshID = UUID()
        studySettingsRefreshID = refreshID
        do {
            let response: StudySettings = try await api.request("/api/study/settings")
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsRefreshID == refreshID,
               studySettingsMutationRevision == mutationRevision
            else { return }
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                setOverview(StudySettingsPolicy.applying(resolvedResponse, to: current))
            }
            studySettingsErrorMessage = nil
        } catch {
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsRefreshID == refreshID,
               studySettingsMutationRevision == mutationRevision
            else { return }
            studySettingsErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateNewCardsPerDay(_ value: Int) async -> Bool {
        await updateStudySettings(
            newCardsPerDay: value,
            lessonBatchSize: studySettings?.lessonBatchSize ?? overview?.lessonBatchSize ?? 5
        )
    }

    @discardableResult
    func updateStudySettings(
        newCardsPerDay: Int,
        lessonBatchSize: Int,
        reviewTimeBudgetMinutes: Int? = nil
    ) async -> Bool {
        guard
            let userID = activeUserID,
            StudySettingsPolicy.accepts(
                newCardsPerDay: newCardsPerDay,
                lessonBatchSize: lessonBatchSize,
                reviewTimeBudgetMinutes: reviewTimeBudgetMinutes
            )
        else { return false }
        let activationGeneration = accountActivationGeneration
        studySettingsMutationRevision += 1
        let updateID = UUID()
        studySettingsUpdateID = updateID
        isUpdatingStudySettings = true
        studySettingsErrorMessage = nil
        defer {
            if isCurrentActivation(userID, generation: activationGeneration),
               studySettingsUpdateID == updateID
            {
                isUpdatingStudySettings = false
                studySettingsUpdateID = nil
            }
        }

        do {
            let response: StudySettings = try await api.request(
                "/api/study/settings",
                method: "PATCH",
                body: UpdateStudySettingsRequest(
                    newCardsPerDay: newCardsPerDay,
                    lessonBatchSize: lessonBatchSize,
                    reviewTimeBudgetMinutes: reviewTimeBudgetMinutes
                )
            )
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsUpdateID == updateID else { return false }
            studySettingsMutationRevision += 1
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                requestedReviewTimeBudget: reviewTimeBudgetMinutes,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                setOverview(StudySettingsPolicy.applying(resolvedResponse, to: current))
            }
            // The server may now admit a different set of new cards and build a
            // different offline reserve. Force the next Study-page entry to refresh.
            lastSyncAt = nil
            lastSessionRefreshAt = nil
            return true
        } catch {
            guard isCurrentActivation(
                userID,
                generation: activationGeneration
            ), studySettingsUpdateID == updateID else { return false }
            studySettingsErrorMessage = error.localizedDescription
            return false
        }
    }

    func refreshNewCardQueue() async throws {
        guard let userID = activeUserID else { return }
        newCardQueueRefreshRevision += 1
        let refreshRevision = newCardQueueRefreshRevision
        isRefreshingNewCardQueue = true
        defer {
            if activeUserID == userID, newCardQueueRefreshRevision == refreshRevision {
                isRefreshingNewCardQueue = false
            }
        }

        let response = try await cardCatalogRepository.newCardQueuePage()
        guard activeUserID == userID, newCardQueueRefreshRevision == refreshRevision else {
            return
        }
        newCardQueue = StudyCardCatalogRepository.appendingUniqueQueueItems(
            response.items,
            to: []
        )
        newCardQueueTotal = response.total
        newCardQueueNextCursor = response.nextCursor
    }

    func loadMoreNewCardQueue() async throws {
        guard
            let userID = activeUserID,
            let cursor = newCardQueueNextCursor,
            !isRefreshingNewCardQueue,
            !isLoadingMoreNewCardQueue,
            newCardQueueReorderToken == nil
        else { return }
        let refreshRevision = newCardQueueRefreshRevision
        isLoadingMoreNewCardQueue = true
        defer {
            if activeUserID == userID {
                isLoadingMoreNewCardQueue = false
            }
        }

        let response = try await cardCatalogRepository.newCardQueuePage(after: cursor)
        guard
            activeUserID == userID,
            newCardQueueRefreshRevision == refreshRevision,
            newCardQueueNextCursor == cursor
        else { return }
        newCardQueue = StudyCardCatalogRepository.appendingUniqueQueueItems(
            response.items,
            to: newCardQueue
        )
        newCardQueueTotal = response.total
        newCardQueueNextCursor = response.nextCursor
    }

    func refreshAllCards(search query: String = "") async throws {
        guard let userID = activeUserID else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        allCardsRefreshRevision += 1
        let refreshRevision = allCardsRefreshRevision
        allCardsQuery = trimmedQuery
        allCardsNextCursor = nil
        isRefreshingAllCards = true
        defer {
            if activeUserID == userID, allCardsRefreshRevision == refreshRevision {
                isRefreshingAllCards = false
            }
        }

        do {
            let response = try await cardCatalogRepository.cardPage(matching: trimmedQuery)
            guard
                activeUserID == userID,
                allCardsRefreshRevision == refreshRevision,
                allCardsQuery == trimmedQuery
            else { return }
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                response.items,
                to: []
            )
            allCardsNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                allCardsRefreshRevision == refreshRevision,
                allCardsQuery == trimmedQuery
            else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            // SwiftData remains the offline source of truth for browsing. The
            // server list is only the paginated presentation when reachable.
            allCards = StudyCardCatalogRepository.cards(
                libraryCards,
                matching: trimmedQuery
            )
            allCardsNextCursor = nil
            throw error
        }
    }

    func loadMoreAllCards() async throws {
        guard
            let userID = activeUserID,
            let cursor = allCardsNextCursor,
            !isRefreshingAllCards,
            !isLoadingMoreAllCards
        else { return }
        let refreshRevision = allCardsRefreshRevision
        isLoadingMoreAllCards = true
        defer {
            if activeUserID == userID {
                isLoadingMoreAllCards = false
            }
        }

        let query = allCardsQuery
        let response = try await cardCatalogRepository.cardPage(
            matching: query,
            after: cursor
        )
        guard
            activeUserID == userID,
            allCardsRefreshRevision == refreshRevision,
            allCardsNextCursor == cursor,
            allCardsQuery == query
        else { return }
        allCards = StudyCardCatalogRepository.appendingUniqueCards(
            response.items,
            to: allCards
        )
        allCardsNextCursor = response.nextCursor
    }

    func learningPath(for card: StudyCard) async throws -> StudyLearningPath {
        let currentCard = try prepareLearningPathAccess(for: card)
        return try await learningPathRepository.learningPath(for: currentCard.reviewCardID)
    }

    func searchLearningPathSuccessors(matching query: String) async throws -> [StudyCard] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        return try await cardCatalogRepository.cardPage(matching: trimmedQuery).items
    }

    func linkLearningPathSuccessor(
        _ successor: StudyCard,
        to predecessor: StudyCard,
        requirement: StudyLearningPathUnlockRequirement
    ) async throws -> StudyLearningPath {
        let currentPredecessor = try prepareLearningPathAccess(for: predecessor)
        let currentSuccessor = try currentLocalCardIfPresent(for: successor) ?? successor
        for identifier in Set([currentSuccessor.id, currentSuccessor.reviewCardID]) {
            guard try !cardOutbox.hasPendingCardWrite(for: identifier) else {
                throw PendingLearningPathChangesError()
            }
        }
        let path = try await learningPathRepository.linkSuccessor(
            currentSuccessor.reviewCardID,
            to: currentPredecessor.reviewCardID,
            requirement: requirement
        )
        try? await refreshLearningItems(search: learningItemsQuery)
        return path
    }

    func refreshLearningItems(search query: String = "") async throws {
        guard let userID = activeUserID else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        learningItemsRefreshRevision += 1
        let refreshRevision = learningItemsRefreshRevision
        learningItemsQuery = trimmedQuery
        learningItemsNextCursor = nil
        isRefreshingLearningItems = true
        defer {
            if activeUserID == userID, learningItemsRefreshRevision == refreshRevision {
                isRefreshingLearningItems = false
            }
        }

        do {
            let response = try await cardCatalogRepository.learningItemPage(
                matching: trimmedQuery
            )
            guard
                activeUserID == userID,
                learningItemsRefreshRevision == refreshRevision,
                learningItemsQuery == trimmedQuery
            else { return }
            learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
                response.items,
                to: []
            )
            reconcilePendingCardMutationsIntoLearningItems()
            learningItemsNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                learningItemsRefreshRevision == refreshRevision,
                learningItemsQuery == trimmedQuery
            else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            learningItems = StudyCardCatalogRepository.standaloneLearningItems(
                from: libraryCards,
                matching: trimmedQuery
            )
            learningItemsNextCursor = nil
            throw error
        }
    }

    func loadMoreLearningItems() async throws {
        guard
            let userID = activeUserID,
            let cursor = learningItemsNextCursor,
            !isRefreshingLearningItems,
            !isLoadingMoreLearningItems
        else { return }
        let refreshRevision = learningItemsRefreshRevision
        let query = learningItemsQuery
        isLoadingMoreLearningItems = true
        defer {
            if activeUserID == userID {
                isLoadingMoreLearningItems = false
            }
        }

        let response = try await cardCatalogRepository.learningItemPage(
            matching: query,
            after: cursor
        )
        guard
            activeUserID == userID,
            learningItemsRefreshRevision == refreshRevision,
            learningItemsNextCursor == cursor,
            learningItemsQuery == query
        else { return }
        learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
            response.items,
            to: learningItems
        )
        reconcilePendingCardMutationsIntoLearningItems()
        learningItemsNextCursor = response.nextCursor
    }

    func card(for item: StudyLearningItemCard) -> StudyCard? {
        let identifiers = [item.id, item.syncId]
        return allCards.first { StudyCardIdentity.matches($0, any: identifiers) }
            ?? libraryCards.first { StudyCardIdentity.matches($0, any: identifiers) }
    }

    func resolveCard(for item: StudyLearningItemCard) async throws -> StudyCard? {
        if let localCard = card(for: item) {
            return localCard
        }
        guard let userID = activeUserID else { return nil }
        let activationGeneration = accountActivationGeneration
        let canonicalCard = try await fetchCanonicalCard(id: item.syncId)
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if let canonicalCard {
            try upsertLocalCard(canonicalCard, markedDirty: false)
            try context.save()
            loadLibraryCards(userID: userID)
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                [canonicalCard],
                to: allCards
            )
        }
        return canonicalCard
    }

    func resolveCard(for item: StudyNewCardQueueItem) async throws -> StudyCard? {
        let identifiers = [item.id]
        if let localCard = allCards.first(where: {
            StudyCardIdentity.matches($0, any: identifiers)
        }) ?? libraryCards.first(where: {
            StudyCardIdentity.matches($0, any: identifiers)
        }) {
            return localCard
        }
        guard let userID = activeUserID else { return nil }
        let activationGeneration = accountActivationGeneration
        let canonicalCard = try await fetchCanonicalCard(id: item.id)
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if let canonicalCard {
            try upsertLocalCard(canonicalCard, markedDirty: false)
            try context.save()
            loadLibraryCards(userID: userID)
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                [canonicalCard],
                to: allCards
            )
        }
        return canonicalCard
    }

    private func upsertAllCardsPresentation(
        _ card: StudyCard,
        addToLearningItemsIfMissing: Bool = false
    ) {
        allCards = StudyCardCatalogRepository.upserting(
            card,
            into: allCards,
            matching: allCardsQuery
        )
        reconcileLearningItems(
            upserting: card,
            addIfMissing: addToLearningItemsIfMissing
        )
    }

    private func reconcileLearningItems(
        upserting card: StudyCard,
        addIfMissing: Bool = false
    ) {
        var foundExistingCard = false
        learningItems = learningItems.compactMap { item in
            let representativeCard = updatedLearningItemCard(
                item.representativeCard,
                from: card,
                foundExistingCard: &foundExistingCard
            )
            let stages = item.stages.map { stage in
                StudyLearningItemStage(
                    number: stage.number,
                    status: stage.status,
                    cardCount: stage.cardCount,
                    representativeCard: updatedLearningItemCard(
                        stage.representativeCard,
                        from: card,
                        foundExistingCard: &foundExistingCard
                    ),
                    cards: stage.cards.map {
                        updatedLearningItemCard(
                            $0,
                            from: card,
                            foundExistingCard: &foundExistingCard
                        )
                    }
                )
            }
            let updatedItem = StudyLearningItem(
                id: item.id,
                groupId: item.groupId,
                representativeCard: representativeCard,
                currentStageNumber: item.currentStageNumber,
                stageCount: item.stageCount,
                cardCount: item.cardCount,
                retiredStageCount: item.retiredStageCount,
                transferDemonstrated: item.transferDemonstrated,
                stages: stages
            )
            return learningItem(updatedItem, matches: learningItemsQuery)
                ? updatedItem
                : nil
        }
        guard addIfMissing,
              !foundExistingCard,
              let standalone = StudyCardCatalogRepository.standaloneLearningItems(
                  from: [card],
                  matching: learningItemsQuery
              ).first
        else { return }
        // Keep optimistic/manual creations visible immediately. A later grouped
        // refresh replaces this projection if the server assigned the card to a family.
        learningItems.insert(standalone, at: 0)
    }

    private func learningItem(_ item: StudyLearningItem, matches query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let cards = [item.representativeCard] + item.stages.flatMap(\.cards)
        return cards.contains {
            $0.displayText.localizedCaseInsensitiveContains(query)
                || ($0.meaning?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func reconcilePendingCardMutationsIntoLearningItems() {
        removeStandaloneItemsDuplicatedByFamilies()
        let pendingDeleteIdentifiers =
            (try? cardOutbox.pendingDeleteIdentifiers()) ?? []
        if !pendingDeleteIdentifiers.isEmpty {
            removeFromLearningItems(matching: pendingDeleteIdentifiers)
        }
        let pendingWriteIdentifiers =
            (try? cardOutbox.pendingWriteIdentifiers()) ?? []
        for card in libraryCards where StudyCardIdentity.matches(
            card,
            any: pendingWriteIdentifiers
        ) {
            reconcileLearningItems(upserting: card, addIfMissing: true)
        }
        removeStandaloneItemsDuplicatedByFamilies()
    }

    private func removeStandaloneItemsDuplicatedByFamilies() {
        let familyCardIdentifiers = Set(
            learningItems
                .filter { $0.groupId != nil }
                .flatMap { item in
                    [item.representativeCard] + item.stages.flatMap(\.cards)
                }
                .flatMap { [$0.id.lowercased(), $0.syncId.lowercased()] }
        )
        guard !familyCardIdentifiers.isEmpty else { return }
        learningItems.removeAll { item in
            item.groupId == nil
                && learningItemCard(
                    item.representativeCard,
                    matchesAny: familyCardIdentifiers
                )
        }
    }

    private func updatedLearningItemCard(
        _ itemCard: StudyLearningItemCard,
        from card: StudyCard,
        foundExistingCard: inout Bool
    ) -> StudyLearningItemCard {
        guard StudyCardIdentity.matches(card, any: [itemCard.id, itemCard.syncId]) else {
            return itemCard
        }
        foundExistingCard = true
        return StudyLearningItemCard(
            id: itemCard.id,
            syncId: itemCard.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            displayText: card.promptText,
            meaning: card.answerText,
            variantKind: itemCard.variantKind
        )
    }

    private func removeFromLearningItems(_ card: StudyCard) {
        removeFromLearningItems(matching: Set([
            card.id.lowercased(),
            card.reviewCardID.lowercased(),
        ]))
    }

    private func removeFromLearningItems(matching identifiers: Set<String>) {
        learningItems = learningItems.compactMap { item in
            if item.groupId == nil {
                let isDeletedCard = learningItemCard(
                    item.representativeCard,
                    matchesAny: identifiers
                )
                return isDeletedCard ? nil : item
            }
            let stages = item.stages.compactMap { stage -> StudyLearningItemStage? in
                let cards = stage.cards.filter {
                    !learningItemCard($0, matchesAny: identifiers)
                }
                guard !cards.isEmpty else { return nil }
                let representativeCard = learningItemCard(
                    stage.representativeCard,
                    matchesAny: identifiers
                ) ? cards[0] : stage.representativeCard
                return StudyLearningItemStage(
                    number: stage.number,
                    status: stage.status,
                    cardCount: cards.count,
                    representativeCard: representativeCard,
                    cards: cards
                )
            }
            guard !stages.isEmpty else { return nil }
            let representativeCard = learningItemCard(
                item.representativeCard,
                matchesAny: identifiers
            ) ? stages[0].representativeCard : item.representativeCard
            let currentStageNumber = item.currentStageNumber.flatMap { currentNumber in
                stages.contains { $0.number == currentNumber } ? currentNumber : nil
            } ?? stages.first(where: { $0.status == .available })?.number
            let updatedItem = StudyLearningItem(
                id: item.id,
                groupId: item.groupId,
                representativeCard: representativeCard,
                currentStageNumber: currentStageNumber,
                stageCount: stages.count,
                cardCount: stages.reduce(0) { $0 + $1.cardCount },
                retiredStageCount: stages.filter { $0.status == .retired }.count,
                transferDemonstrated: item.transferDemonstrated,
                stages: stages
            )
            return learningItem(updatedItem, matches: learningItemsQuery)
                ? updatedItem
                : nil
        }
    }

    private func learningItemCard(
        _ card: StudyLearningItemCard,
        matchesAny identifiers: Set<String>
    ) -> Bool {
        identifiers.contains(card.id.lowercased())
            || identifiers.contains(card.syncId.lowercased())
    }

    func moveNewCards(fromOffsets: IndexSet, toOffset: Int) async throws {
        guard
            let userID = activeUserID,
            !fromOffsets.isEmpty,
            !isRefreshingNewCardQueue,
            !isLoadingMoreNewCardQueue,
            newCardQueueReorderToken == nil
        else { return }
        let reorderToken = UUID()
        newCardQueueReorderToken = reorderToken
        defer {
            if newCardQueueReorderToken == reorderToken {
                newCardQueueReorderToken = nil
            }
        }
        let refreshRevision = newCardQueueRefreshRevision
        let previousItems = newCardQueue
        newCardQueue.move(fromOffsets: fromOffsets, toOffset: toOffset)

        do {
            let response = try await cardCatalogRepository.reorderNewCards(
                newCardQueue.map(\.id)
            )
            guard
                activeUserID == userID,
                newCardQueueRefreshRevision == refreshRevision
            else { return }
            newCardQueue = response.items
            newCardQueueTotal = response.total
            newCardQueueNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                newCardQueueRefreshRevision == refreshRevision
            else { return }
            newCardQueue = previousItems
            throw error
        }
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
            let orderedNewCards = StudySessionPolicy.orderedCards(newlyDueCards)
            cards = preservingCurrentOrder
                ? cards + orderedNewCards
                : StudySessionPolicy.orderedCards(cards + orderedNewCards)
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

    @discardableResult
    func recordReview(
        card: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date = .now
    ) async -> String? {
        await recordReviewResult(
            card: card,
            rating: rating,
            duration: duration,
            reviewedAt: reviewedAt
        )?.eventID
    }

    @discardableResult
    func recordReviewResult(
        card: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date = .now
    ) async -> StagedStudyReview? {
        guard let userID = activeUserID else { return nil }
        guard storageMode == .persistent else {
            storageWriteErrorMessage = StorageWriteUnavailableError(domain: .study)
                .localizedDescription
            return nil
        }
        defer {
            refreshPendingOfflineReviewCount()
            reloadFailedStudyChanges()
        }
        let activationGeneration = accountActivationGeneration
        var stagedReview: StagedStudyReview?
        do {
            // Scheduling must succeed before the durable event is staged. If the
            // FSRS engine violates its rating-state contract, surface that error
            // without leaving a review queued against an unchanged local card.
            let staged = try reviewRecordingService.stage(
                card: card,
                rating: rating,
                duration: duration,
                reviewedAt: reviewedAt,
                deviceID: deviceID,
                queueIndex: cards.count
            )
            stagedReview = staged
            // Publish the durable queue state before attempting the network flush.
            // Session completion can render while that request is still in flight.
            refreshPendingOfflineReviewCount()
            let currentCard = staged.cardBefore
            let updatedCard = staged.cardAfter
            let identifiers = StudyCardIdentity.identifiers(for: currentCard)
                .union(StudyCardIdentity.identifiers(for: card))
            sessionCompletedCardIDs.insert(currentCard.id)
            // The animation retains this reviewed card as its presentation snapshot until
            // dismissal, while the queue can optimistically advance underneath it.
            masteryAnimation = nil
            // Compare the same local FSRS projection on both sides. The server annotation
            // belongs to the pre-review state and cannot describe this optimistic review.
            let oldLevel = currentCard.fsrsMasteryLevel
            let newLevel = updatedCard.fsrsMasteryLevel
            masteryAnimation = (
                id: UUID(),
                card: currentCard,
                label: currentCard.presentation.back.heading
                    ?? currentCard.presentation.front.heading
                    ?? "This item",
                fromLevel: oldLevel.rawValue,
                toLevel: newLevel.rawValue,
                passed: rating != .again
            )
            sessionFailureWasPresentByEventID[staged.eventID] = sessionFailedCardIDs.contains(
                currentCard.id
            )
            if rating == .again {
                sessionFailedCardIDs.insert(currentCard.id)
            } else {
                sessionFailedCardIDs.remove(currentCard.id)
            }
            var pendingState = PendingReviewState(
                newlyFailedCardIDs: newlyFailedCardIDs,
                retainedFailedCardIDs: retainedFailedCardIDs,
                resolvedFailedCardIDs: resolvedFailedCardIDs
            )
            pendingState.record(
                card: PendingReviewCardState(card: currentCard),
                rating: rating
            )
            apply(pendingState)
            consumeOverviewCount(for: currentCard)
            cards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
            if let index = libraryCards.firstIndex(where: {
                StudyCardIdentity.matches($0, any: identifiers)
            }) {
                libraryCards[index] = updatedCard
            } else {
                libraryCards.append(updatedCard)
            }
            scheduleNextOfflineActivation()
            if try cardOutbox.hasPendingCreate(for: currentCard.id) {
                try await flushCardOutbox()
            }
            try await flushSchedulingOutboxes()
            return staged
        } catch {
            var schedulerStateRecovered = false
            if error is FSRSReviewScheduler.InvalidSchedulerTimestampError {
                schedulerStateRecovered = await recoverCorruptedSchedulerState(
                    for: card,
                    userID: userID,
                    activationGeneration: activationGeneration
                )
            }
            markOutboxRetryNeeded(for: error)
            if !schedulerStateRecovered {
                handleSyncError(
                    error,
                    for: userID,
                    activationGeneration: activationGeneration
                )
            }
            return stagedReview
        }
    }

    func undoReview(eventID: String, cardBefore: StudyCard) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let presentationRevision = studySurfaceRevision
        let undoingPresentedLesson = lessonSessionIsPresented
        await reviewOutbox.waitForCurrentFlush()
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        guard try !cardOutbox.hasPendingDelete(for: cardBefore) else {
            throw DeletedCardUndoError()
        }
        if try reviewOutbox.stageRemoval(eventID: eventID) {
            // The view may hold a pre-reconciliation snapshot. For a locally
            // pending undo, preserve the latest local presentation while
            // restoring the scheduling state captured before the review.
            let restoredCard = try restoreReviewedCard(
                cardBefore,
                preservingLocalPresentation: true,
                presentationRevision: presentationRevision,
                undoingPresentedLesson: undoingPresentedLesson
            )
            apply(try reviewOutbox.pendingState())
            restoreSessionFailure(
                for: restoredCard.id,
                before: eventID,
                presentationRevision: presentationRevision
            )
            return
        }

        let response: UndoStudyReviewResponse = try await api.request(
            "/api/study/reviews/undo",
            method: "POST",
            body: UndoStudyReviewRequest(
                reviewLogId: eventID.lowercased(),
                timeZone: TimeZone.current.identifier,
                currentOverview: overview
            )
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        let restoredCard = try restoreReviewedCard(
            response.card,
            presentationRevision: presentationRevision,
            undoingPresentedLesson: undoingPresentedLesson
        )
        let reviewTimeBudgetMinutes = resolvedReviewTimeBudget(from: response.overview)
        setOverview(response.overview.updatingReviewTimeBudget(
            to: reviewTimeBudgetMinutes,
            fallbackJLPTMastery: overview?.jlptMastery
        ))
        apply(try reviewOutbox.pendingState())
        restoreSessionFailure(
            for: restoredCard.id,
            before: eventID,
            presentationRevision: presentationRevision
        )
    }

    private func resolvedReviewTimeBudget(from responseOverview: StudyOverview? = nil) -> Int {
        StudySettingsPolicy.resolvedReviewTimeBudget(
            responseOverview: responseOverview,
            settings: studySettings,
            currentOverview: overview
        )
    }

    private func restoreSessionFailure(
        for cardID: String,
        before eventID: String,
        presentationRevision: Int
    ) {
        guard let wasPresent = sessionFailureWasPresentByEventID.removeValue(forKey: eventID) else {
            return
        }
        guard presentationRevision == studySurfaceRevision else { return }
        if wasPresent {
            sessionFailedCardIDs.insert(cardID)
        } else {
            sessionFailedCardIDs.remove(cardID)
        }
    }

    func createCard(
        expression: String,
        reading: String,
        meaning: String
    ) async throws {
        var draft = StudyCardDraft()
        draft.cueText = expression
        draft.cueReading = reading
        draft.answerExpression = expression
        draft.answerMeaning = meaning
        try await createCard(draft)
    }

    func refreshManualDrafts() async throws {
        try await manualDraftOutbox.refresh()
    }

    @discardableResult
    func queueManualDraft(
        creationKind: StudyCardCreationKind,
        draft: StudyCardDraft,
        id: String = ClientIdentifier.ulid()
    ) async throws -> StudyManualCardDraft {
        try requirePersistentWrites()
        guard activeUserID != nil else { throw CancellationError() }
        let request = CreateStudyManualCardDraftRequest(
            id: id,
            creationKind: creationKind,
            cardType: creationKind.cardType.rawValue,
            prompt: creationKind == .audioRecognition ? .object([:]) : draft.prompt(),
            answer: draft.answer(),
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty
        )
        return try await manualDraftOutbox.queueCreate(request)
    }

    @discardableResult
    func updateManualDraft(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue? = nil,
        previewAudioRole: String? = nil,
        previewImage: JSONValue? = nil
    ) async throws -> StudyManualCardDraft {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        var prompt = draft.prompt(merging: serverDraft.prompt)
        var answer = draft.answer(merging: serverDraft.answer)
        if let previewAudio {
            if previewAudioRole == "prompt" {
                prompt = prompt.replacingObjectValues(["cueAudio": previewAudio])
                answer = answer.replacingObjectValues(["answerAudio": previewAudio])
            } else if previewAudioRole == "answer" {
                answer = answer.replacingObjectValues(["answerAudio": previewAudio])
            }
        }
        if let previewImage {
            if draft.imagePlacement.includesPrompt {
                prompt = prompt.replacingObjectValues(["cueImage": previewImage])
            }
            if draft.imagePlacement.includesAnswer {
                answer = answer.replacingObjectValues(["answerImage": previewImage])
            }
        }
        let resolvedPreviewAudio = previewAudio ?? serverDraft.previewAudio
        let resolvedPreviewAudioRole = previewAudio == nil
            ? serverDraft.previewAudioRole
            : previewAudioRole
        let resolvedPreviewImage = previewImage ?? serverDraft.previewImage
        let request = UpdateStudyManualCardDraftRequest(
            prompt: prompt,
            answer: answer,
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty,
            previewAudio: resolvedPreviewAudio ?? .null,
            previewAudioRole: resolvedPreviewAudioRole.map(JSONValue.string) ?? .null,
            previewImage: resolvedPreviewImage ?? .null
        )
        let updated: StudyManualCardDraft = try await api.request(
            "/api/study/card-drafts/\(serverDraft.id)",
            method: "PATCH",
            body: request
        )
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        manualDraftOutbox.replace(updated)
        return updated
    }

    func generateManualDraftPreviewAudio(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewImage: JSONValue?
    ) async throws -> DraftPreviewAudioResult {
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let updated = try await updateManualDraft(
            serverDraft,
            draft: draft,
            previewImage: previewImage
        )
        let response: StudyCardDraftPreviewAudioResponse = try await api.request(
            "/api/study/card-drafts/\(updated.id)/preview-audio",
            method: "POST",
            timeout: 180
        )
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        let refreshed = try await fetchManualDraft(id: updated.id)
        let localURL: URL?
        if let remoteURL = response.previewAudio?.mediaURLs.first {
            localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
        } else {
            localURL = nil
        }
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        return DraftPreviewAudioResult(draft: refreshed, localURL: localURL)
    }

    func generateManualDraftPreviewImage(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?
    ) async throws -> DraftPreviewImageResult {
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let updated = try await updateManualDraft(
            serverDraft,
            draft: draft,
            previewAudio: previewAudio,
            previewAudioRole: previewAudioRole
        )
        let response: StudyCardDraftImageResponse = try await api.request(
            "/api/study/card-drafts/\(updated.id)/preview-image",
            method: "POST",
            timeout: 180
        )
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        guard let remoteURL = response.previewImage.mediaURLs.first else {
            throw MissingGeneratedCardImageError()
        }
        let localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        let refreshed = try await fetchManualDraft(id: updated.id)
        return DraftPreviewImageResult(draft: refreshed, localURL: localURL)
    }

    func createCard(
        from serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?,
        previewImage: JSONValue?
    ) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let recoveryState = manualDraftOutbox.recoveryState(for: serverDraft.id)
        let shouldUpdateDraft = recoveryState == .none || recoveryState == .rejected
        let updated = if shouldUpdateDraft {
            try await updateManualDraft(
                serverDraft,
                draft: draft,
                previewAudio: previewAudio,
                previewAudioRole: previewAudioRole,
                previewImage: previewImage
            )
        } else {
            serverDraft
        }
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        try await manualDraftOutbox.commit(draftID: updated.id) { [weak self] card in
            guard let self, self.isCurrentActivation(
                userID,
                generation: activationGeneration
            ) else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(
                card,
                userID: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    func deleteManualDraft(_ serverDraft: StudyManualCardDraft) async throws {
        try requirePersistentWrites()
        try await manualDraftOutbox.deleteDraft(id: serverDraft.id)
    }

    func hasPendingDraftCommit(for draftID: String) -> Bool {
        manualDraftOutbox.hasPendingCommit(for: draftID)
    }

    func draftCommitRecoveryState(for draftID: String) -> DraftCommitRecoveryState {
        manualDraftOutbox.recoveryState(for: draftID)
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
        var draft = StudyCardDraft(card: card)
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
        try cardOutbox.stageUpdate(cardID: currentCard.id, request: projection.request)
        cards = cards.map { $0.id == currentCard.id ? updated : $0 }
        libraryCards = libraryCards.map { $0.id == currentCard.id ? updated : $0 }
        allCards = allCards.map { $0.id == currentCard.id ? updated : $0 }
        reconcileLearningItems(upserting: updated)
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
        guard
            !imagePrompt.isEmpty,
            imagePrompt.count <= 1_000
        else {
            throw InvalidCardImagePromptError()
        }
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        let currentCard = try await prepareCardMediaMutation(for: card, medium: "image")
        return try await cardMediaService.regenerateImage(
            currentCard: currentCard,
            prompt: imagePrompt,
            placement: placement,
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
        // As above, reject invalid editor state before the outbox preflight.
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        let currentCard = try await prepareCardMediaMutation(for: card, medium: "image")
        return try await cardMediaService.uploadImage(
            currentCard: currentCard,
            jpegData: jpegData,
            placement: placement,
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

    private func prepareLearningPathAccess(for card: StudyCard) throws -> StudyCard {
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

    func reloadFailedStudyChanges() {
        guard let userID = activeUserID else {
            failedStudyChanges = []
            return
        }
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.userID == userID && $0.lastError != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        failedStudyChanges = ((try? context.fetch(descriptor)) ?? [])
            .compactMap { $0.failedStudyChange() }
    }

    func retryFailedStudyChange(id: String) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        guard failedStudyChangeOperationIDs.insert(id).inserted else { return }
        defer { failedStudyChangeOperationIDs.remove(id) }
        let activationGeneration = accountActivationGeneration
        guard let mutation = try failedMutation(id: id, userID: userID),
              let kind = mutation.studyMutationKind
        else { return }
        guard mutation.failedStudyChange()?.isRetryable != false else { return }

        mutation.lastError = nil
        try context.save()
        reloadFailedStudyChanges()

        do {
            switch kind {
            case .cardCreate, .cardUpdate, .cardDelete:
                try await flushCardOutbox()
            case .cardAction, .review:
                try await flushSchedulingOutboxes()
                restorePendingReviewState()
            }
        } catch {
            if kind == .review {
                restorePendingReviewState()
            }
            markOutboxRetryNeeded(for: error)
            handleSyncError(
                error,
                for: userID,
                activationGeneration: activationGeneration
            )
            reloadFailedStudyChanges()
            throw error
        }
        reloadFailedStudyChanges()
    }

    func discardFailedStudyChange(id: String) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        guard failedStudyChangeOperationIDs.insert(id).inserted else { return }
        defer { failedStudyChangeOperationIDs.remove(id) }
        guard let mutation = try failedMutation(id: id, userID: userID),
              let kind = mutation.studyMutationKind
        else { return }

        let resourceID = mutation.resourceID.lowercased()
        let canonicalLookupID: String? = if kind == .review {
            try canonicalReviewCardID(for: mutation, userID: userID)
        } else {
            mutation.resourceID
        }
        let canonicalCard: StudyCard? = if kind == .cardDelete
            || kind == .cardUpdate
            || kind == .cardAction
            || kind == .review
        {
            if let canonicalLookupID {
                try await fetchCanonicalCard(id: canonicalLookupID)
            } else {
                nil
            }
        } else {
            nil
        }
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        guard let currentMutation = try failedMutation(id: id, userID: userID),
              currentMutation.studyMutationKind == kind
        else { return }
        if kind == .cardCreate
            || ((kind == .cardUpdate || kind == .cardAction || kind == .review)
                && canonicalCard == nil)
        {
            // A review/update against a card the server rejected cannot succeed on
            // its own. The same is true when an edited server card no longer exists.
            try discardLocalCardActivity(userID: userID, resourceID: resourceID)
        } else {
            context.delete(currentMutation)
            let remaining = try context.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.userID == userID }
                )
            ).contains {
                $0.id != id
                    && $0.resourceID.lowercased() == resourceID
                    && $0.studyMutationKind != nil
            }
            if (kind == .cardUpdate || kind == .cardAction) && !remaining {
                try localRecords(userID: userID, matching: resourceID).forEach {
                    $0.locallyUpdatedAt = nil
                }
            }
            // Any remaining card write or review owns the optimistic replica.
            // Restoring a server snapshot here would clobber that newer local work.
            if !remaining, let canonicalCard {
                try upsertLocalCard(
                    canonicalCard,
                    markedDirty: false,
                    serverUpdatedAt: canonicalCard.updatedAt
                )
            }
        }
        try context.save()
        restorePendingReviewState()
        loadLocalCards(userID: userID)
        loadLibraryCards(userID: userID)
        reloadFailedStudyChanges()

        // Discarding removes the row that intentionally blocked inbound data.
        // Reconcile immediately when online; ordinary sync will retry later if not.
        await synchronize()
    }

    private func fetchCanonicalCard(id: String) async throws -> StudyCard? {
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

    private func canonicalReviewCardID(
        for mutation: PendingMutation,
        userID: Int
    ) throws -> String? {
        let directCandidates = [
            reviewOutbox.cardID(for: mutation),
            mutation.resourceID,
        ]
        if let identifier = directCandidates.compactMap({ $0 }).first(where: {
            ClientIdentifier.isULID($0)
        }) {
            return identifier.lowercased()
        }

        let resourceID = mutation.resourceID.lowercased()
        for record in try localRecords(userID: userID, matching: resourceID) {
            let candidates = [
                record.syncID,
                (try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                ))?.reviewCardID,
            ]
            if let identifier = candidates.compactMap({ $0 }).first(where: {
                ClientIdentifier.isULID($0)
            }) {
                return identifier.lowercased()
            }
        }
        return nil
    }

    private func recoverCorruptedSchedulerState(
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

    private func failedMutation(id: String, userID: Int) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID && $0.id == id && $0.lastError != nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func discardLocalCardActivity(userID: Int, resourceID: String) throws {
        let related = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == userID }
            )
        ).filter { $0.resourceID.lowercased() == resourceID }
        related.forEach(context.delete)
        for record in try localRecords(userID: userID, matching: resourceID) {
            context.delete(record)
        }
    }

    private func localRecords(
        userID: Int,
        matching normalizedResourceID: String
    ) throws -> [LocalCardRecord] {
        try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        ).filter { record in
            if record.id.lowercased() == normalizedResourceID
                || record.syncID.lowercased() == normalizedResourceID
            {
                return true
            }
            guard let card = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            ) else { return false }
            return StudyCardIdentity.matches(card, any: [normalizedResourceID])
        }
    }

    private func consumeOverviewCount(for card: StudyCard) {
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

    private func flushCardOutbox() async throws {
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
            }
        ) { [weak self] acknowledgement in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            var acknowledgedCard = try acknowledgedCard(
                acknowledgement.card,
                preservingPendingReview: acknowledgement.preservingPendingReview,
                preservingPendingEdit: acknowledgement.preservingPendingEdit
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
                    cardType: acknowledgedCard.cardType,
                    prompt: acknowledgedCard.prompt,
                    answer: acknowledgedCard.answer,
                    state: latestLocalCard.state,
                    answerAudioSource: acknowledgedCard.answerAudioSource,
                    masteryLevel: latestLocalCard.masteryLevel,
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
                    cardType: acknowledged.cardType,
                    prompt: acknowledged.prompt,
                    answer: acknowledged.answer,
                    state: latestLocalCard.state,
                    answerAudioSource: acknowledged.answerAudioSource,
                    masteryLevel: latestLocalCard.masteryLevel,
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

    private func flushSchedulingOutboxes() async throws {
        while true {
            let before = try reviewOutbox.pendingDeliverableCount()
                + cardActionOutbox.pendingDeliverableCount()
            guard before > 0 else { return }

            if let reviewEventOutboxFlushOverride {
                try await reviewEventOutboxFlushOverride()
            } else {
                try await reviewOutbox.flush()
            }
            try await flushCardActionOutbox()

            let after = try reviewOutbox.pendingDeliverableCount()
                + cardActionOutbox.pendingDeliverableCount()
            guard after > 0, after < before else { return }
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

    private func restorePendingReviewState() {
        guard let state = try? reviewOutbox.pendingState() else { return }
        apply(state)
    }

    private func apply(_ state: PendingReviewState) {
        newlyFailedCardIDs = state.newlyFailedCardIDs
        retainedFailedCardIDs = state.retainedFailedCardIDs
        resolvedFailedCardIDs = state.resolvedFailedCardIDs
    }

    @discardableResult
    private func restoreReviewedCard(
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
        let preserveLocalPresentation = preservingLocalPresentation
            || record.locallyUpdatedAt != nil
        guard record.id != card.id || preserveLocalPresentation else {
            return card
        }

        return StudyCard(
            id: record.id,
            syncId: card.syncId ?? localCard?.syncId,
            noteId: card.noteId,
            cardType: preserveLocalPresentation
                ? localCard?.cardType ?? card.cardType
                : card.cardType,
            prompt: preserveLocalPresentation
                ? localCard?.prompt ?? card.prompt
                : card.prompt,
            answer: preserveLocalPresentation
                ? localCard?.answer ?? card.answer
                : card.answer,
            state: card.state,
            answerAudioSource: preserveLocalPresentation
                ? localCard?.answerAudioSource ?? card.answerAudioSource
                : card.answerAudioSource,
            // Scheduling state and mastery come from the undo result; neither is editor-owned.
            masteryLevel: card.masteryLevel,
            createdAt: preserveLocalPresentation
                ? localCard?.createdAt ?? card.createdAt
                : card.createdAt,
            updatedAt: preserveLocalPresentation
                ? localCard?.updatedAt ?? card.updatedAt
                : card.updatedAt
        )
    }

    private func markPrepared(cards: [StudyCard], clearingOtherRecords: Bool = false) {
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
        preservingPendingEdit: Bool
    ) throws -> StudyCard {
        guard preservingPendingReview || preservingPendingEdit else { return serverCard }
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

        return StudyCard(
            id: record.id,
            // Keep the persisted local key while carrying the server-resolved identity as its alias.
            syncId: record.id == serverCard.id
                ? serverCard.syncId ?? localCard.syncId
                : serverCard.reviewCardID,
            noteId: serverCard.noteId,
            cardType: serverCard.cardType,
            prompt: preservingPendingEdit ? localCard.prompt : serverCard.prompt,
            answer: preservingPendingEdit ? localCard.answer : serverCard.answer,
            state: preservingPendingReview ? localCard.state : serverCard.state,
            answerAudioSource: serverCard.answerAudioSource,
            // Current PATCH responses return computed, non-null mastery; legacy lean
            // responses may omit it. Editor input cannot clear mastery. If that contract
            // gains explicit clears, decoding must distinguish null from omission.
            masteryLevel: preservingPendingReview
                ? localCard.masteryLevel
                : serverCard.masteryLevel ?? localCard.masteryLevel,
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

    private func currentLocalCardIfPresent(for card: StudyCard) throws -> StudyCard? {
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

    private func upsertLocalCard(
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

    private func fetchManualDraft(id: String) async throws -> StudyManualCardDraft {
        try await manualDraftOutbox.fetch(id: id)
    }

    func retryPendingDraftCreates() async throws {
        try requirePersistentWrites()
        try await manualDraftOutbox.retryPendingCreates()
    }

    private func retryPendingDraftMutations(
        userID: Int,
        activationGeneration: Int
    ) async throws {
        try await manualDraftOutbox.retryPendingMutations { [weak self] card in
            guard let self, self.isCurrentActivation(
                userID,
                generation: activationGeneration
            ) else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(
                card,
                userID: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    func retryPendingDraftCommits() async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        try await manualDraftOutbox.retryPendingCommits { [weak self] card in
            guard let self, self.isCurrentActivation(
                userID,
                generation: activationGeneration
            ) else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(
                card,
                userID: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    private func applyCommittedManualDraftCard(
        _ card: StudyCard,
        userID: Int,
        activationGeneration: Int
    ) async throws {
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        try upsertLocalCard(card, markedDirty: false)
        if !lessonSessionIsPresented {
            cards.removeAll { $0.id.lowercased() == card.id.lowercased() }
            cards.append(card)
            cards = StudySessionPolicy.orderedCards(cards)
        }
        libraryCards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        libraryCards.append(card)
        upsertAllCardsPresentation(card, addToLearningItemsIfMissing: true)
        try context.save()
        await mediaCache.prepare(urls: card.mediaURLs, category: "active-study")
    }

    // Internal so concurrency tests can model a completed local mutation while
    // an older list request is still in flight.
    func replaceManualDraft(_ draft: StudyManualCardDraft) {
        manualDraftOutbox.replace(draft)
    }

    private func loadLocalCards(userID: Int) {
        studySurfaceRevision += 1
        cards = (try? localCardRepository.activeCards(userID: userID)) ?? []
        cards = StudySessionPolicy.orderedCards(cards)
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
        cards = preserved + StudySessionPolicy.orderedCards(
            Array(persistedByNormalizedID.values)
        )
    }

    private func loadLibraryCards(userID: Int) {
        libraryCards = (try? localCardRepository.libraryCards(userID: userID)) ?? []
    }

    private func loadCachedOverview(userID: Int) {
        var descriptor = FetchDescriptor<LocalStudyOverviewSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard let snapshot = try? overviewContext.fetch(descriptor).first else { return }
        overviewSnapshot = snapshot
        guard let cachedOverview = try? StorageCodec.decoder.decode(
                StudyOverview.self,
                from: snapshot.payload
            ) else { return }

        overview = cachedOverview
        studySettings = StudySettingsPolicy.settings(
            from: cachedOverview,
            fallbackReviewTimeBudget: cachedOverview.reviewTimeBudgetMinutes ?? 90
        )
    }

    private func setOverview(
        _ value: StudyOverview,
        persistImmediately: Bool = true
    ) {
        overview = value
        guard let userID = activeUserID else { return }

        do {
            let payload = try StorageCodec.encoder.encode(value)
            let snapshot: LocalStudyOverviewSnapshot
            if let overviewSnapshot, overviewSnapshot.userID == userID {
                snapshot = overviewSnapshot
            } else {
                var descriptor = FetchDescriptor<LocalStudyOverviewSnapshot>(
                    predicate: #Predicate { $0.userID == userID }
                )
                descriptor.fetchLimit = 1
                if let existing = try overviewContext.fetch(descriptor).first {
                    snapshot = existing
                } else {
                    snapshot = LocalStudyOverviewSnapshot(userID: userID, payload: payload)
                    overviewContext.insert(snapshot)
                }
                overviewSnapshot = snapshot
            }
            snapshot.payload = payload
            snapshot.updatedAt = .now
            if persistImmediately {
                persistPendingOverviewSnapshot()
            } else {
                scheduleOverviewSnapshotSave()
            }
        } catch {
            // The snapshot is a disposable presentation cache. Study cards and
            // queued reviews remain durable even if this best-effort save fails.
            overviewContext.rollback()
            overviewSnapshot = nil
        }
    }

    private func scheduleOverviewSnapshotSave() {
        overviewSnapshotSaveTask?.cancel()
        overviewSnapshotSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.persistPendingOverviewSnapshot()
        }
    }

    private func persistPendingOverviewSnapshot() {
        overviewSnapshotSaveTask?.cancel()
        overviewSnapshotSaveTask = nil
        guard overviewContext.hasChanges else { return }
        do {
            try overviewContext.save()
        } catch {
            // This dedicated context contains only the disposable presentation
            // snapshot, so rollback can never discard cards or outbox mutations.
            overviewContext.rollback()
            overviewSnapshot = nil
        }
    }

    private func scheduleNextOfflineActivation() {
        dueActivationScheduler.cancel()
        guard !lessonSessionIsPresented, let dueAt = nextOfflineDueAt else {
            return
        }
        dueActivationScheduler.schedule(at: dueAt) { [weak self, dueActivationScheduler] in
            self?.activateOfflineDueCards(at: dueActivationScheduler.now)
        }
    }

    private func handleSyncError(_ error: any Error) {
        if let urlError = error as? URLError, [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
        ].contains(urlError.code) {
            syncStatus = .offline
        } else {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    static func requiresAutomaticRetry(_ error: any Error) -> Bool {
        !(error is QuarantinedCardMutationError
            || error is QuarantinedCardActionError
            || error is QuarantinedReviewError
            || error is FSRSReviewScheduler.InvalidSchedulerTimestampError)
    }

    private func markOutboxRetryNeeded(for error: any Error) {
        if Self.requiresAutomaticRetry(error) {
            outboxRetryRevision += 1
        }
    }

    private func requirePersistentWrites() throws {
        guard storageMode == .persistent else {
            throw StorageWriteUnavailableError(domain: .study)
        }
    }

    private func handleSyncError(
        _ error: any Error,
        for userID: Int,
        activationGeneration: Int
    ) {
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        handleSyncError(error)
    }

    private func isCurrentActivation(_ userID: Int, generation: Int) -> Bool {
        activeUserID == userID && accountActivationGeneration == generation
    }
}

private extension String {
    var nilIfTrimmedEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

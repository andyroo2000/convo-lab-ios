import Foundation
import SwiftData

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
    private let mediaCache: MediaCache
    private let knownKanjiService: KnownKanjiService
    private let reviewOutbox: ReviewEventOutbox
    private let cardOutbox: CardMutationOutbox
    private let manualDraftOutbox: ManualDraftOutbox
    private let cardMediaService: CardMediaMutationService
    private let cardSyncFeedRepository: CardSyncFeedRepository
    private let localCardRepository: StudyCardLocalRepository
    private let cardCatalogRepository: StudyCardCatalogRepository
    private let reviewProjection: (StudyCard, ReviewRating, Date) throws -> StudyCard
    private let deviceID: String
    @ObservationIgnored private var allCardsRefreshRevision = 0
    @ObservationIgnored private var newCardQueueRefreshRevision = 0
    @ObservationIgnored private var newCardQueueReorderToken: UUID?
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var newlyFailedCardIDs: Set<String> = []
    @ObservationIgnored private var retainedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var resolvedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var sessionFailureWasPresentByEventID: [String: Bool] = [:]
    @ObservationIgnored private var offlineDueActivationTimer: Timer?

    private(set) var cards: [StudyCard] = []
    private(set) var libraryCards: [StudyCard] = []
    private(set) var allCards: [StudyCard] = []
    private(set) var allCardsNextCursor: String?
    private(set) var allCardsQuery = ""
    private(set) var isRefreshingAllCards = false
    private(set) var isLoadingMoreAllCards = false
    private(set) var newCardQueue: [StudyNewCardQueueItem] = []
    private(set) var newCardQueueTotal = 0
    private(set) var newCardQueueNextCursor: String?
    private(set) var isRefreshingNewCardQueue = false
    private(set) var isLoadingMoreNewCardQueue = false
    var manualDrafts: [StudyManualCardDraft] { manualDraftOutbox.drafts }
    private(set) var overview: StudyOverview?
    private(set) var studySettings: StudySettings?
    private(set) var isUpdatingStudySettings = false
    private(set) var studySettingsErrorMessage: String?
    var knownKanji: Set<Character> { knownKanjiService.knownKanji }
    var manualKnownKanji: Set<Character> { knownKanjiService.manualKnownKanji }
    var knownKanjiVersion: Int { knownKanjiService.version }
    var wanikaniConnected: Bool { knownKanjiService.wanikaniConnected }
    var wanikaniLastSyncedAt: Date? { knownKanjiService.wanikaniLastSyncedAt }
    var isWaniKaniWorking: Bool { knownKanjiService.isWorking }
    var wanikaniErrorMessage: String? { knownKanjiService.errorMessage }
    private(set) var resolvingPitchAccentCardIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncAt: Date?
    private(set) var sessionInitialCardCount = 0
    private(set) var sessionCompletedCardIDs: Set<String> = []
    private(set) var sessionFailedCardIDs: Set<String> = []
    private(set) var sessionKind = "reviews"
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

    func beginLessonSessionPresentation() {
        lessonSessionIsPresented = true
    }

    func endLessonSessionPresentation() {
        lessonSessionIsPresented = false
        if sessionKind == "lessons" {
            sessionKind = "reviews"
            if let userID = activeUserID {
                try? localCardRepository.replaceActiveSession(with: [], userID: userID)
            }
            cards = []
            sessionInitialCardCount = 0
            sessionCompletedCardIDs = []
        }
    }

    init(
        initialUserID: Int? = nil,
        api: APIClient,
        context: ModelContext,
        mediaCache: MediaCache,
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
        self.mediaCache = mediaCache
        knownKanjiService = KnownKanjiService(api: api, context: context)
        let reviewOutbox = ReviewEventOutbox(api: api, context: context)
        self.reviewOutbox = reviewOutbox
        cardOutbox = CardMutationOutbox(
            api: api,
            context: context,
            reviewOutbox: reviewOutbox
        )
        manualDraftOutbox = ManualDraftOutbox(api: api, context: context)
        cardMediaService = CardMediaMutationService(api: api, mediaCache: mediaCache)
        cardSyncFeedRepository = CardSyncFeedRepository(api: api, context: context)
        localCardRepository = StudyCardLocalRepository(context: context)
        cardCatalogRepository = StudyCardCatalogRepository(api: api)
        self.reviewProjection = reviewProjection
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
        loadLocalCards(userID: userID)
        loadLibraryCards(userID: userID)
        reviewOutbox.activate(userID: userID)
        cardOutbox.activate(userID: userID)
        manualDraftOutbox.activate(userID: userID)
        cardMediaService.activate(userID: userID)
        cardSyncFeedRepository.activate(userID: userID)
        restorePendingReviewState()
        knownKanjiService.activate(userID: userID)
        activateOfflineDueCards(preservingCurrentOrder: false)
    }

    func deactivate() {
        offlineDueActivationTimer?.invalidate()
        offlineDueActivationTimer = nil
        activeUserID = nil
        mediaCache.deactivate()
        knownKanjiService.deactivate()
        cardOutbox.deactivate()
        manualDraftOutbox.deactivate()
        cardMediaService.deactivate()
        cardSyncFeedRepository.deactivate()
        reviewOutbox.deactivate()
        cards = []
        libraryCards = []
        allCards = []
        allCardsNextCursor = nil
        allCardsQuery = ""
        allCardsRefreshRevision += 1
        isRefreshingAllCards = false
        isLoadingMoreAllCards = false
        newCardQueue = []
        newCardQueueTotal = 0
        newCardQueueNextCursor = nil
        newCardQueueRefreshRevision += 1
        newCardQueueReorderToken = nil
        isRefreshingNewCardQueue = false
        isLoadingMoreNewCardQueue = false
        overview = nil
        studySettings = nil
        isUpdatingStudySettings = false
        studySettingsErrorMessage = nil
        newlyFailedCardIDs = []
        retainedFailedCardIDs = []
        resolvedFailedCardIDs = []
        sessionFailureWasPresentByEventID = [:]
        syncStatus = .idle
        lastSyncAt = nil
        sessionInitialCardCount = 0
        sessionCompletedCardIDs = []
        sessionFailedCardIDs = []
        sessionKind = "reviews"
        lessonSessionIsPresented = false
        masteryAnimation = nil
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
        try knownKanjiService.stageLocalDataDeletion(userID: userID)
        cards.forEach(context.delete)
        mutations.forEach(context.delete)
        syncStates.forEach(context.delete)
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
        guard
            card.answer["pitchAccent"]?["status"]?.stringValue == nil,
            resolvingPitchAccentCardIDs.insert(card.id).inserted
        else {
            return
        }
        defer { resolvingPitchAccentCardIDs.remove(card.id) }

        do {
            try await flushCardOutbox()
            guard
                let currentCard = cards.first(where: { $0.id == card.id }),
                currentCard.answer["pitchAccent"]?["status"]?.stringValue == nil
            else {
                return
            }
            // The ConvoLab-compatible pitch endpoint returns StudyCard directly,
            // matching the direct card create/update compatibility responses.
            let serverCard: StudyCard = try await api.request(
                "/api/study/cards/\(currentCard.reviewCardID)/pitch-accent",
                method: "POST"
            )
            guard
                try !cardOutbox.hasPendingDelete(for: card),
                let pitchAccent = serverCard.answer["pitchAccent"]
            else {
                return
            }
            let cardID = card.id
            var descriptor = FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID && $0.id == cardID }
            )
            descriptor.fetchLimit = 1
            guard
                let record = try context.fetch(descriptor).first,
                let latestCard = try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                )
            else {
                return
            }
            let updatedCard = StudyCardEditorProjection.reconcilingMedia(
                latest: latestCard,
                serverCard: serverCard,
                prompt: latestCard.prompt,
                answer: latestCard.answer.replacingObjectValues([
                    "pitchAccent": pitchAccent,
                ]),
                answerAudioSource: latestCard.answerAudioSource,
                updatedAt: latestCard.updatedAt
            )
            record.replacePayload(encoded: try StorageCodec.encoder.encode(updatedCard))
            record.serverUpdatedAt = max(record.serverUpdatedAt, serverCard.updatedAt)
            cards = cards.map { $0.id == card.id ? updatedCard : $0 }
            libraryCards = libraryCards.map { $0.id == card.id ? updatedCard : $0 }
            allCards = allCards.map { $0.id == card.id ? updatedCard : $0 }
            try context.save()
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
        guard let userID = activeUserID, syncStatus != .syncing else { return }
        syncStatus = .syncing
        var firstError: (any Error)?
        var refreshed = false
        var checkpointWasReset = false

        do {
            try await flushCardOutbox()
        } catch {
            firstError = error
        }
        guard activeUserID == userID else { return }
        do {
            try await retryPendingDraftMutations(userID: userID)
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }
        do {
            try await reviewOutbox.flush()
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }
        do {
            var cardsReconciler = StudyPublishedCardReconciler()
            var libraryCardsReconciler = StudyPublishedCardReconciler()
            var allCardsReconciler = StudyPublishedCardReconciler()
            let result = try await cardSyncFeedRepository.pullChanges { changes in
                cardsReconciler.apply(changes, to: &self.cards)
                libraryCardsReconciler.apply(changes, to: &self.libraryCards)
                allCardsReconciler.apply(changes, to: &self.allCards)
            }
            switch result {
            case let .completed(deletedCardIdentifiers):
                prunePublishedCards(matching: deletedCardIdentifiers)
            case let .checkpointReset(deletedCardIdentifiers):
                checkpointWasReset = true
                loadLocalCards(userID: userID)
                loadLibraryCards(userID: userID)
                prunePublishedCards(matching: deletedCardIdentifiers)
            case .discardedStaleResponse:
                return
            }
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }
        // Fetch small, user-visible metadata before session media preparation
        // consumes the shared production request bucket.
        do {
            try await refreshKnownKanji()
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }
        do {
            refreshed = try await refreshSessionPreservingActiveLessons()
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }
        do {
            try await refreshOfflineReserve(
                userID: userID,
                clearingOtherRecords: checkpointWasReset || refreshed
            )
        } catch {
            firstError = firstError ?? error
        }
        guard activeUserID == userID else { return }

        if refreshed {
            lastSyncAt = .now
        }
        if let firstError {
            handleSyncError(firstError)
        } else {
            syncStatus = .idle
        }
    }

    private func prunePublishedCards(matching identifiers: Set<String>) {
        StudyPublishedCardReconciler.prune(&cards, matching: identifiers)
        StudyPublishedCardReconciler.prune(&libraryCards, matching: identifiers)
        StudyPublishedCardReconciler.prune(&allCards, matching: identifiers)
    }

    func synchronizeIfNeeded(maxAge: Duration) async {
        guard syncStatus != .syncing else { return }
        let components = maxAge.components
        let maxAgeSeconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        if let lastSyncAt, Date.now.timeIntervalSince(lastSyncAt) < maxAgeSeconds {
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

    func refreshSession() async throws {
        guard let userID = activeUserID else { return }
        let timeZone = TimeZone.current.identifier
        let response: StudySessionResponse = try await api.request(
            "/api/study/session/start",
            method: "POST",
            body: ["time_zone": timeZone]
        )
        let session = response.session
        guard activeUserID == userID else { return }
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
        overview = StudySettingsPolicy.applying(resolvedSettings, to: session.overview)
        studySettings = resolvedSettings
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
        markPrepared(cards: activeCards)
    }

    /// A foreground sync must not replace a frozen lesson batch with review cards.
    /// The lesson remains stable until the user finishes it or explicitly leaves it.
    func refreshSessionPreservingActiveLessons() async throws -> Bool {
        guard !lessonSessionIsPresented else { return false }
        try await refreshSession()
        return true
    }

    func refreshLessons() async throws {
        guard let userID = activeUserID else { return }
        let timeZone = TimeZone.current.identifier
        let response: StudySessionResponse = try await api.request(
            "/api/study/lessons/start",
            method: "POST",
            body: ["time_zone": timeZone]
        )
        let session = response.session
        guard activeUserID == userID else { return }
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
        overview = StudySettingsPolicy.applying(resolvedSettings, to: session.overview)
        studySettings = resolvedSettings
        cards = lessonCards
        sessionKind = "lessons"
        sessionInitialCardCount = lessonCards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        try localCardRepository.replaceActiveSession(with: lessonCards, userID: userID)
        loadLibraryCards(userID: userID)
        let mediaURLs = lessonCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-lesson")
        markPrepared(cards: lessonCards)
    }

    private func eligibleSessionCards(
        from candidates: [StudyCard],
        pendingReviewState: PendingReviewState
    ) throws -> [StudyCard] {
        guard activeUserID != nil else { return [] }
        let pendingDeleteIdentifiers = try cardOutbox.pendingDeleteIdentifiers()
        let candidatesWithoutPendingDeletes = candidates.filter { card in
            !StudyCardIdentity.matches(card, any: pendingDeleteIdentifiers)
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
        do {
            let response: StudySettings = try await api.request("/api/study/settings")
            guard activeUserID == userID else { return }
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                overview = StudySettingsPolicy.applying(resolvedResponse, to: current)
            }
            studySettingsErrorMessage = nil
        } catch {
            guard activeUserID == userID else { return }
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
        isUpdatingStudySettings = true
        studySettingsErrorMessage = nil
        defer {
            if activeUserID == userID {
                isUpdatingStudySettings = false
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
            guard activeUserID == userID else { return false }
            let resolvedResponse = StudySettingsPolicy.resolving(
                response,
                requestedReviewTimeBudget: reviewTimeBudgetMinutes,
                fallbackReviewTimeBudget: resolvedReviewTimeBudget()
            )
            studySettings = resolvedResponse
            if let current = overview {
                overview = StudySettingsPolicy.applying(resolvedResponse, to: current)
            }
            // The server may now admit a different set of new cards and build a
            // different offline reserve. Force the next Study-page entry to refresh.
            lastSyncAt = nil
            return true
        } catch {
            guard activeUserID == userID else { return false }
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

    private func upsertAllCardsPresentation(_ card: StudyCard) {
        allCards = StudyCardCatalogRepository.upserting(
            card,
            into: allCards,
            matching: allCardsQuery
        )
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
        clearingOtherRecords: Bool
    ) async throws {
        let reserve: StudyOfflineReserve = try await api.request(
            "/api/study/offline-reserve",
            method: "POST"
        )
        guard activeUserID == userID else { return }
        try localCardRepository.mergeOfflineReserve(reserve.cards, userID: userID)
        loadLibraryCards(userID: userID)
        scheduleNextOfflineActivation()
        await mediaCache.prepare(
            urls: reserve.cards.flatMap(\.mediaURLs),
            category: "offline-study"
        )
        markPrepared(
            cards: cards + reserve.cards,
            clearingOtherRecords: clearingOtherRecords
        )
    }

    func refreshKnownKanji() async throws {
        try await knownKanjiService.refresh()
    }

    func activateOfflineDueCards(
        at date: Date = .now,
        preservingCurrentOrder: Bool = true
    ) {
        guard let userID = activeUserID else { return }
        let records = (try? context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && !$0.isInActiveSession
                }
            )
        )) ?? []
        let pendingDeleteIDs = (try? cardOutbox.pendingDeleteIdentifiers()) ?? []
        var activeCardIdentifiers = cards.reduce(into: Set<String>()) {
            $0.formUnion(StudyCardIdentity.identifiers(for: $1))
        }
        var newlyDueCards: [StudyCard] = []
        var changed = false

        for record in records {
            guard
                let card = try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                ),
                !StudyCardIdentity.matches(card, any: pendingDeleteIDs),
                card.isEligibleForOfflineStudy(at: date)
            else {
                continue
            }
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if activeCardIdentifiers.isDisjoint(with: identifiers) {
                activeCardIdentifiers.formUnion(identifiers)
                newlyDueCards.append(card)
                changed = true
                if !record.isInActiveSession {
                    record.isInActiveSession = true
                    changed = true
                }
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
        guard let userID = activeUserID else { return nil }
        let now = reviewedAt
        let event = ReviewBatchRequest.Event(
            id: ClientIdentifier.ulid(date: now),
            cardID: card.reviewCardID,
            rating: rating,
            reviewedAt: now,
            durationMilliseconds: duration.map {
                let components = $0.components
                return Int(
                    components.seconds * 1_000
                        + components.attoseconds / 1_000_000_000_000_000
                )
            },
            clientEventID: UUID().uuidString.lowercased(),
            deviceID: deviceID,
            clientCreatedAt: now
        )
        var queuedLocally = false
        do {
            // Scheduling must succeed before the durable event is staged. If the
            // FSRS engine violates its rating-state contract, surface that error
            // without leaving a review queued against an unchanged local card.
            let updatedCard = try reviewProjection(card, rating, now)
            try reviewOutbox.stageEnqueue(event: event, cardBefore: card)
            let cardID = card.id
            var descriptor = FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID && $0.id == cardID }
            )
            descriptor.fetchLimit = 1
            sessionCompletedCardIDs.insert(card.id)
            // The animation retains this reviewed card as its presentation snapshot until
            // dismissal, while the queue can optimistically advance underneath it.
            masteryAnimation = nil
            // Compare the same local FSRS projection on both sides. The server annotation
            // belongs to the pre-review state and cannot describe this optimistic review.
            let oldLevel = card.fsrsMasteryLevel
            let newLevel = updatedCard.fsrsMasteryLevel
            masteryAnimation = (
                id: UUID(),
                card: card,
                label: card.presentation.back.heading
                    ?? card.presentation.front.heading
                    ?? "This item",
                fromLevel: oldLevel.rawValue,
                toLevel: newLevel.rawValue,
                passed: rating != .again
            )
            let updatedPayload = try StorageCodec.encoder.encode(updatedCard)
            if let record = try context.fetch(descriptor).first {
                record.replacePayload(encoded: updatedPayload)
                record.isInActiveSession = false
            } else {
                let record = LocalCardRecord(
                    card: updatedCard,
                    userID: userID,
                    queueIndex: cards.count,
                    payload: updatedPayload
                )
                record.isInActiveSession = false
                context.insert(record)
            }
            try context.save()
            queuedLocally = true
            sessionFailureWasPresentByEventID[event.id] = sessionFailedCardIDs.contains(card.id)
            if rating == .again {
                sessionFailedCardIDs.insert(card.id)
            } else {
                sessionFailedCardIDs.remove(card.id)
            }
            var pendingState = PendingReviewState(
                newlyFailedCardIDs: newlyFailedCardIDs,
                retainedFailedCardIDs: retainedFailedCardIDs,
                resolvedFailedCardIDs: resolvedFailedCardIDs
            )
            pendingState.record(
                card: PendingReviewCardState(card: card),
                rating: rating
            )
            apply(pendingState)
            consumeOverviewCount(for: card)
            cards.removeAll { $0.id == card.id }
            if let index = libraryCards.firstIndex(where: { $0.id == card.id }) {
                libraryCards[index] = updatedCard
            } else {
                libraryCards.append(updatedCard)
            }
            scheduleNextOfflineActivation()
            if try cardOutbox.hasPendingCreate(for: card.id) {
                try await flushCardOutbox()
            }
            try await reviewOutbox.flush()
        } catch {
            handleSyncError(error)
        }
        return queuedLocally ? event.id : nil
    }

    func undoReview(eventID: String, cardBefore: StudyCard) async throws {
        await reviewOutbox.waitForCurrentFlush()
        guard try !cardOutbox.hasPendingDelete(for: cardBefore) else {
            throw DeletedCardUndoError()
        }
        if try reviewOutbox.stageRemoval(eventID: eventID) {
            try restoreReviewedCard(cardBefore)
            apply(try reviewOutbox.pendingState())
            restoreSessionFailure(for: cardBefore.id, before: eventID)
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
        try restoreReviewedCard(response.card)
        let reviewTimeBudgetMinutes = resolvedReviewTimeBudget(from: response.overview)
        overview = response.overview.updatingReviewTimeBudget(to: reviewTimeBudgetMinutes)
        apply(try reviewOutbox.pendingState())
        restoreSessionFailure(for: cardBefore.id, before: eventID)
    }

    private func resolvedReviewTimeBudget(from responseOverview: StudyOverview? = nil) -> Int {
        StudySettingsPolicy.resolvedReviewTimeBudget(
            responseOverview: responseOverview,
            settings: studySettings,
            currentOverview: overview
        )
    }

    private func restoreSessionFailure(for cardID: String, before eventID: String) {
        guard let wasPresent = sessionFailureWasPresentByEventID.removeValue(forKey: eventID) else {
            return
        }
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
        guard let userID = activeUserID else { throw CancellationError() }
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
        guard activeUserID == userID else { throw CancellationError() }
        manualDraftOutbox.replace(updated)
        return updated
    }

    func generateManualDraftPreviewAudio(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewImage: JSONValue?
    ) async throws -> DraftPreviewAudioResult {
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
        let refreshed = try await fetchManualDraft(id: updated.id)
        let localURL: URL?
        if let remoteURL = response.previewAudio?.mediaURLs.first {
            localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
        } else {
            localURL = nil
        }
        return DraftPreviewAudioResult(draft: refreshed, localURL: localURL)
    }

    func generateManualDraftPreviewImage(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?
    ) async throws -> DraftPreviewImageResult {
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
        guard let remoteURL = response.previewImage.mediaURLs.first else {
            throw MissingGeneratedCardImageError()
        }
        let localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
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
        guard let userID = activeUserID else { throw CancellationError() }
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
        guard activeUserID == userID else { throw CancellationError() }
        try await manualDraftOutbox.commit(draftID: updated.id) { [weak self] card in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(card, userID: userID)
        }
    }

    func deleteManualDraft(_ serverDraft: StudyManualCardDraft) async throws {
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
        guard let userID = activeUserID else { throw CancellationError() }
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
        upsertAllCardsPresentation(optimistic)
        try context.save()

        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
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
        guard activeUserID != nil else { throw CancellationError() }
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
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
    }

    func deleteCard(_ card: StudyCard) async throws {
        guard let userID = activeUserID else { throw CancellationError() }
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
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
    }

    func regenerateAnswerAudio(
        for card: StudyCard,
        voiceID: String,
        textOverride: String
    ) async throws -> AnswerAudioRegenerationResult {
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
        }
        let currentCard = try currentLocalCard(for: card)
        guard try !cardOutbox.hasPendingCardWrite(for: currentCard.id) else {
            throw PendingCardChangesError(medium: medium)
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

    private func consumeOverviewCount(for card: StudyCard) {
        guard let current = overview else { return }
        overview = StudyOverview(
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
            learningReadiness: current.learningReadiness
        )
    }

    func dismissMasteryAnimation() {
        masteryAnimation = nil
    }

    private func flushCardOutbox() async throws {
        guard let userID = activeUserID else { return }
        let activeCardOrder = cards.map { $0.id.lowercased() }
        try await cardOutbox.flush(
            onDrainFinished: { [weak self] in
                guard let self, self.activeUserID == userID else { return }
                // Reconciliation can rename or remove records. Refresh once after
                // the drain while preserving an in-progress session's order.
                loadLocalCards(preservingNormalizedOrder: activeCardOrder, userID: userID)
                loadLibraryCards(userID: userID)
            }
        ) { [weak self] acknowledgement in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            let acknowledgedCard = try acknowledgedCard(
                acknowledgement.card,
                preservingPendingReview: acknowledgement.preservingPendingReview,
                preservingPendingEdit: acknowledgement.preservingPendingEdit
            )
            try updateExistingLocalCard(
                acknowledgedCard,
                markedDirty: acknowledgement.preservingPendingEdit,
                serverUpdatedAt: acknowledgement.card.updatedAt,
                missingRecordError: MissingAcknowledgedCardError()
            )
        }
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

    private func restoreReviewedCard(_ card: StudyCard) throws {
        guard try !cardOutbox.hasPendingDelete(for: card) else {
            throw DeletedCardUndoError()
        }
        let record = try localCardRecord(for: card)
        let restoredCard = restoredCard(card, matching: record)
        let normalizedID = restoredCard.id.lowercased()
        masteryAnimation = nil
        sessionCompletedCardIDs = Set(
            sessionCompletedCardIDs.filter { $0.lowercased() != normalizedID }
        )

        cards.removeAll { $0.id.lowercased() == normalizedID }
        cards.insert(restoredCard, at: 0)
        if let index = libraryCards.firstIndex(
            where: { $0.id.lowercased() == normalizedID }
        ) {
            libraryCards[index] = restoredCard
        } else {
            libraryCards.append(restoredCard)
        }
        upsertAllCardsPresentation(restoredCard)

        let payload = try StorageCodec.encoder.encode(restoredCard)
        if let record {
            let wasLocallyUpdated = record.locallyUpdatedAt != nil
            record.replacePayload(encoded: payload)
            record.isInActiveSession = true
            if !wasLocallyUpdated {
                record.serverUpdatedAt = restoredCard.updatedAt
            }
        } else {
            guard let userID = activeUserID else { throw CancellationError() }
            context.insert(
                LocalCardRecord(
                    card: restoredCard,
                    userID: userID,
                    queueIndex: 0,
                    payload: payload
                )
            )
        }
        guard let userID = activeUserID else { throw CancellationError() }
        try localCardRepository.replaceActiveSession(with: cards, userID: userID)
        scheduleNextOfflineActivation()
    }

    private func restoredCard(
        _ card: StudyCard,
        matching record: LocalCardRecord?
    ) -> StudyCard {
        guard let record else { return card }
        let localCard = try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        guard record.id != card.id || record.locallyUpdatedAt != nil else {
            return card
        }

        return StudyCard(
            id: record.id,
            syncId: card.syncId ?? localCard?.syncId,
            noteId: card.noteId,
            cardType: record.locallyUpdatedAt == nil
                ? card.cardType
                : localCard?.cardType ?? card.cardType,
            prompt: record.locallyUpdatedAt == nil
                ? card.prompt
                : localCard?.prompt ?? card.prompt,
            answer: record.locallyUpdatedAt == nil
                ? card.answer
                : localCard?.answer ?? card.answer,
            state: card.state,
            answerAudioSource: record.locallyUpdatedAt == nil
                ? card.answerAudioSource
                : localCard?.answerAudioSource ?? card.answerAudioSource,
            // Scheduling state and mastery come from the undo result; neither is editor-owned.
            masteryLevel: card.masteryLevel,
            createdAt: record.locallyUpdatedAt == nil
                ? card.createdAt
                : localCard?.createdAt ?? card.createdAt,
            updatedAt: record.locallyUpdatedAt == nil
                ? card.updatedAt
                : localCard?.updatedAt ?? card.updatedAt
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
        if
            let record = try localCardRecord(for: card),
            let current = try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        {
            return current
        }

        throw MissingLocalCardError()
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
        try await manualDraftOutbox.retryPendingCreates()
    }

    private func retryPendingDraftMutations(userID: Int) async throws {
        try await manualDraftOutbox.retryPendingMutations { [weak self] card in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(card, userID: userID)
        }
    }

    func retryPendingDraftCommits() async throws {
        guard let userID = activeUserID else { return }
        try await manualDraftOutbox.retryPendingCommits { [weak self] card in
            guard let self, self.activeUserID == userID else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(card, userID: userID)
        }
    }

    private func applyCommittedManualDraftCard(
        _ card: StudyCard,
        userID: Int
    ) async throws {
        guard activeUserID == userID else { throw CancellationError() }
        try upsertLocalCard(card, markedDirty: false)
        cards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        cards.append(card)
        cards = StudySessionPolicy.orderedCards(cards)
        libraryCards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        libraryCards.append(card)
        upsertAllCardsPresentation(card)
        try context.save()
        await mediaCache.prepare(urls: card.mediaURLs, category: "active-study")
    }

    // Internal so concurrency tests can model a completed local mutation while
    // an older list request is still in flight.
    func replaceManualDraft(_ draft: StudyManualCardDraft) {
        manualDraftOutbox.replace(draft)
    }

    private func loadLocalCards(userID: Int) {
        cards = (try? localCardRepository.activeCards(userID: userID)) ?? []
        cards = StudySessionPolicy.orderedCards(cards)
    }

    private func loadLocalCards(
        preservingNormalizedOrder order: [String],
        userID: Int
    ) {
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

    private func scheduleNextOfflineActivation() {
        offlineDueActivationTimer?.invalidate()
        guard let dueAt = nextOfflineDueAt else {
            offlineDueActivationTimer = nil
            return
        }
        let timer = Timer(timeInterval: max(0, dueAt.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activateOfflineDueCards()
            }
        }
        offlineDueActivationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
}

private extension String {
    var nilIfTrimmedEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

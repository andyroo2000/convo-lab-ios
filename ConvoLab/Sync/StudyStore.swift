import Foundation
import SwiftData

@Observable
final class StudyStore {
    private struct PendingReviewCardState: Codable {
        let id: String
        let failedAt: Date?

        init(card: StudyCard) {
            id = card.id
            failedAt = card.state.failedAt
        }

        init(id: String, failedAt: Date?) {
            self.id = id
            self.failedAt = failedAt
        }
    }

    private struct PendingReviewPayload: Codable {
        let event: ReviewBatchRequest.Event
        let cardBefore: PendingReviewCardState
    }

    private struct LegacyPendingReviewPayload: Codable {
        let event: ReviewBatchRequest.Event
        let cardBefore: StudyCard
    }

    private struct PendingReviewState {
        var cardIDs: Set<String> = []
        var newlyFailedCardIDs: Set<String> = []
        var retainedFailedCardIDs: Set<String> = []
        var resolvedFailedCardIDs: Set<String> = []

        mutating func record(card: PendingReviewCardState, rating: ReviewRating) {
            if rating == .again {
                let wasResolved = resolvedFailedCardIDs.remove(card.id) != nil
                if newlyFailedCardIDs.contains(card.id) {
                    retainedFailedCardIDs.remove(card.id)
                } else if wasResolved || card.failedAt != nil {
                    retainedFailedCardIDs.insert(card.id)
                } else {
                    newlyFailedCardIDs.insert(card.id)
                }
            } else {
                let wasNewlyFailed = newlyFailedCardIDs.remove(card.id) != nil
                retainedFailedCardIDs.remove(card.id)
                if card.failedAt != nil, !wasNewlyFailed {
                    resolvedFailedCardIDs.insert(card.id)
                }
            }
        }
    }

    private struct QuarantinedReviewError: LocalizedError {
        let count: Int

        var errorDescription: String? {
            "\(count) review \(count == 1 ? "event was" : "events were") rejected and held for inspection."
        }
    }

    private struct QuarantinedCardError: LocalizedError {
        let count: Int

        var errorDescription: String? {
            "\(count) card \(count == 1 ? "change was" : "changes were") rejected and held for inspection."
        }
    }

    private struct MissingLocalCardError: LocalizedError {
        var errorDescription: String? {
            "This card changed during sync. Close the editor and try again."
        }
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case offline
        case failed(String)
    }

    private let api: APIClient
    private let context: ModelContext
    private let mediaCache: MediaCache
    private let deviceID: String
    @ObservationIgnored private var cardOutboxFlushTask: Task<Void, Error>?
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var newlyFailedCardIDs: Set<String> = []
    @ObservationIgnored private var retainedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var resolvedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var offlineDueActivationTimer: Timer?

    private(set) var cards: [StudyCard] = []
    private(set) var libraryCards: [StudyCard] = []
    private(set) var overview: StudyOverview?
    private(set) var knownKanji: Set<Character> = []
    private(set) var manualKnownKanji: Set<Character> = []
    private(set) var knownKanjiVersion = -1
    private(set) var wanikaniConnected = false
    private(set) var wanikaniLastSyncedAt: Date?
    private(set) var isWaniKaniWorking = false
    private(set) var wanikaniErrorMessage: String?
    private(set) var resolvingPitchAccentCardIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncAt: Date?

    init(api: APIClient, context: ModelContext, mediaCache: MediaCache) {
        self.api = api
        self.context = context
        self.mediaCache = mediaCache
        deviceID = ClientIdentifier.deviceID()
        loadLocalCards()
        loadLibraryCards()
        restorePendingReviewState()
        activateOfflineDueCards(preservingCurrentOrder: false)
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        loadKnownKanji(userID: userID)
    }

    var fiveDayNewCardTarget: Int {
        (overview?.newCardsPerDay ?? 0) * 5
    }

    var sessionCounts: StudySessionCounts {
        StudySessionCounts.calculate(
            cards: cards,
            overview: overview,
            newlyFailedCardIDs: newlyFailedCardIDs,
            retainedFailedCardIDs: retainedFailedCardIDs,
            resolvedFailedCardIDs: resolvedFailedCardIDs
        )
    }

    private var nextOfflineDueAt: Date? {
        let activeCardIDs = Set(cards.map(\.id))
        return libraryCards.compactMap { card in
            guard !activeCardIDs.contains(card.id) else { return nil }
            guard ["learning", "review", "relearning"].contains(card.state.queueState) else {
                return nil
            }
            return card.state.dueAt
        }
        .filter { $0 > .now }
        .min()
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
                try !hasPendingDelete(for: card.id),
                let pitchAccent = serverCard.answer["pitchAccent"]
            else {
                return
            }
            let cardID = card.id
            var descriptor = FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.id == cardID }
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
            let updatedCard = StudyCard(
                id: latestCard.id,
                syncId: latestCard.syncId,
                noteId: latestCard.noteId,
                cardType: latestCard.cardType,
                prompt: latestCard.prompt,
                answer: latestCard.answer.replacingObjectValues([
                    "pitchAccent": pitchAccent,
                ]),
                state: latestCard.state,
                answerAudioSource: latestCard.answerAudioSource,
                createdAt: latestCard.createdAt,
                updatedAt: latestCard.updatedAt
            )
            record.payload = try StorageCodec.encoder.encode(updatedCard)
            record.serverUpdatedAt = max(record.serverUpdatedAt, serverCard.updatedAt)
            cards = cards.map { $0.id == card.id ? updatedCard : $0 }
            libraryCards = libraryCards.map { $0.id == card.id ? updatedCard : $0 }
            try context.save()
        } catch {
            // Pitch accent is optional enrichment. Offline and unresolved cards
            // remain fully studyable and can retry on a later reveal.
        }
    }

    var preparedCardCount: Int {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate {
                $0.isInActiveSession && $0.mediaPreparedAt != nil
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func synchronize() async {
        guard syncStatus != .syncing else { return }
        syncStatus = .syncing
        var firstError: (any Error)?
        var refreshed = false

        do {
            try await flushCardOutbox()
        } catch {
            firstError = error
        }
        do {
            try await flushReviewOutbox()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await refreshSession()
            refreshed = true
        } catch {
            firstError = firstError ?? error
        }
        if activeUserID != nil {
            do {
                try await refreshKnownKanji()
            } catch {
                firstError = firstError ?? error
            }
        }

        if refreshed {
            lastSyncAt = .now
        }
        if let firstError {
            handleSyncError(firstError)
        } else {
            syncStatus = .idle
        }
    }

    func refreshSession() async throws {
        let timeZone = TimeZone.current.identifier
        let envelope: APIEnvelope<StudySession> = try await api.request(
            "/api/study/session/start",
            method: "POST",
            body: ["time_zone": timeZone]
        )
        let pendingReviewState = try pendingReviewState()
        var seenCardIDs: Set<String> = []
        let activeCards = Self.orderSessionCards(try envelope.data.cards.filter { card in
            try !hasPendingDelete(for: card.id)
                && !pendingReviewState.cardIDs.contains(card.id)
                && seenCardIDs.insert(card.id).inserted
        })
        overview = envelope.data.overview
        cards = activeCards
        apply(pendingReviewState)
        try persist(cards: activeCards)
        loadLibraryCards()
        scheduleNextOfflineActivation()

        let mediaURLs = activeCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-study")
        markPrepared(cards: activeCards)
    }

    func refreshKnownKanji() async throws {
        guard let activeUserID else { return }
        let snapshot: KnownKanjiSnapshot = try await api.request("/api/study/known-kanji")
        try apply(snapshot, userID: activeUserID)
    }

    func activateOfflineDueCards(
        at date: Date = .now,
        preservingCurrentOrder: Bool = true
    ) {
        let records = (try? context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { !$0.isInActiveSession }
            )
        )) ?? []
        let pendingDeleteIDs = Set(
            ((try? context.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "cardDelete" }
                )
            )) ?? []).map(\.resourceID)
        )
        var activeCardIDs = Set(cards.map(\.id))
        var newlyDueCards: [StudyCard] = []
        var changed = false

        for record in records {
            guard !pendingDeleteIDs.contains(record.id) else { continue }
            guard
                let card = try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                ),
                card.isEligibleForOfflineStudy(at: date)
            else {
                continue
            }
            if activeCardIDs.insert(card.id).inserted {
                newlyDueCards.append(card)
                changed = true
            }
            if !record.isInActiveSession {
                record.isInActiveSession = true
                changed = true
            }
        }

        if changed {
            let orderedNewCards = Self.orderSessionCards(newlyDueCards)
            cards = preservingCurrentOrder
                ? cards + orderedNewCards
                : Self.orderSessionCards(cards + orderedNewCards)
            do {
                try context.save()
            } catch {
                handleSyncError(error)
            }
        }
        scheduleNextOfflineActivation()
    }

    func connectWaniKani(apiToken: String) async {
        guard let userID = activeUserID, !isWaniKaniWorking else { return }
        isWaniKaniWorking = true
        wanikaniErrorMessage = nil
        defer { isWaniKaniWorking = false }

        do {
            let snapshot: KnownKanjiSnapshot = try await api.request(
                "/api/study/wanikani",
                method: "PUT",
                body: ConnectWaniKaniRequest(apiToken: apiToken)
            )
            try apply(snapshot, userID: userID)
            try await synchronizeWaniKani(userID: userID)
        } catch {
            wanikaniErrorMessage = error.localizedDescription
        }
    }

    func syncWaniKani() async {
        guard let userID = activeUserID, !isWaniKaniWorking else { return }
        isWaniKaniWorking = true
        wanikaniErrorMessage = nil
        defer { isWaniKaniWorking = false }

        do {
            try await synchronizeWaniKani(userID: userID)
        } catch {
            wanikaniErrorMessage = error.localizedDescription
        }
    }

    func disconnectWaniKani() async {
        guard let userID = activeUserID, !isWaniKaniWorking else { return }
        isWaniKaniWorking = true
        wanikaniErrorMessage = nil
        defer { isWaniKaniWorking = false }

        do {
            let _: IgnoredResponse = try await api.request(
                "/api/study/wanikani",
                method: "DELETE"
            )
            guard activeUserID == userID else { return }
            try await refreshKnownKanji()
        } catch {
            wanikaniErrorMessage = error.localizedDescription
        }
    }

    func recordReview(
        card: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date = .now
    ) async {
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
        do {
            let payload = try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: card)
                )
            )
            context.insert(PendingMutation(kind: "review", resourceID: card.id, payload: payload))
            let cardID = card.id
            var descriptor = FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.id == cardID }
            )
            descriptor.fetchLimit = 1
            let updatedCard = card.applyingReview(rating, at: now)
            let updatedPayload = try StorageCodec.encoder.encode(updatedCard)
            if let record = try context.fetch(descriptor).first {
                record.payload = updatedPayload
                record.isInActiveSession = false
            } else {
                let record = LocalCardRecord(
                    card: updatedCard,
                    queueIndex: cards.count,
                    payload: updatedPayload
                )
                record.isInActiveSession = false
                context.insert(record)
            }
            try context.save()
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
            cards.removeAll { $0.id == card.id }
            if let index = libraryCards.firstIndex(where: { $0.id == card.id }) {
                libraryCards[index] = updatedCard
            } else {
                libraryCards.append(updatedCard)
            }
            scheduleNextOfflineActivation()
            if try hasPendingCreate(for: card.id) {
                try await flushCardOutbox()
            }
            try await flushReviewOutbox()
        } catch {
            handleSyncError(error)
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

    func createCard(_ draft: StudyCardDraft) async throws {
        let id = ClientIdentifier.ulid()
        let prompt = draft.prompt()
        let answer = draft.answer()
        let request = CreateStudyCardRequest(
            id: id,
            cardType: draft.cardType.rawValue,
            prompt: prompt,
            answer: answer
        )
        let now = Date.now
        let optimistic = StudyCard(
            id: id,
            syncId: id,
            noteId: nil,
            cardType: draft.cardType.rawValue,
            prompt: prompt,
            answer: answer,
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: now,
            updatedAt: now
        )
        let mutationData = try StorageCodec.encoder.encode(request)
        let cardData = try StorageCodec.encoder.encode(optimistic)
        let record = LocalCardRecord(card: optimistic, queueIndex: cards.count, payload: cardData)
        record.locallyUpdatedAt = now
        context.insert(record)
        context.insert(PendingMutation(kind: "cardCreate", resourceID: id, payload: mutationData))
        cards.append(optimistic)
        libraryCards.append(optimistic)
        try context.save()

        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
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
        let currentCard = try currentLocalCard(for: card)
        let promptPayload = draft.prompt(merging: currentCard.prompt)
        let answerPayload = draft.answer(merging: currentCard.answer)
        let request = UpdateStudyCardRequest(prompt: promptPayload, answer: answerPayload)
        let updated = StudyCard(
            id: currentCard.id,
            syncId: currentCard.syncId,
            noteId: currentCard.noteId,
            cardType: currentCard.cardType,
            prompt: promptPayload,
            answer: answerPayload,
            state: currentCard.state,
            answerAudioSource: currentCard.answerAudioSource,
            createdAt: currentCard.createdAt,
            updatedAt: .now
        )
        try updateLocalCard(updated, markedDirty: true)
        context.insert(PendingMutation(
            kind: "cardUpdate",
            resourceID: currentCard.id,
            payload: try StorageCodec.encoder.encode(request)
        ))
        cards = cards.map { $0.id == currentCard.id ? updated : $0 }
        libraryCards = libraryCards.map { $0.id == currentCard.id ? updated : $0 }
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
    }

    func deleteCard(_ card: StudyCard) async throws {
        let currentCard = try currentLocalCard(for: card)
        context.insert(PendingMutation(
            kind: "cardDelete",
            resourceID: currentCard.id,
            payload: Data()
        ))
        let cardID = currentCard.id
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        if let record = try context.fetch(descriptor).first {
            context.delete(record)
        }
        cards.removeAll { $0.id == currentCard.id }
        libraryCards.removeAll { $0.id == currentCard.id }
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
    }

    var quarantinedMutationCount: Int {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.lastError != nil }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func flushReviewOutbox() async throws {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.kind == "review" && $0.lastError == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pending = try context.fetch(descriptor)
        guard !pending.isEmpty else { return }

        var quarantinedCount = 0
        for mutation in pending {
            if try hasPendingCreate(for: mutation.resourceID) {
                continue
            }
            let event = try decodePendingReview(mutation.payload).event
            do {
                let _: IgnoredResponse = try await api.request(
                    "/api/card-review-events/batch",
                    method: "POST",
                    body: ReviewBatchRequest(events: [event])
                )
                context.delete(mutation)
                try context.save()
            } catch let APIClientError.rejected(status, message)
                where [400, 404, 409, 410, 422].contains(status)
            {
                mutation.attemptCount += 1
                mutation.lastAttemptAt = .now
                mutation.lastError = "HTTP \(status): \(message)"
                try context.save()
                quarantinedCount += 1
            } catch {
                mutation.attemptCount += 1
                mutation.lastAttemptAt = .now
                mutation.lastError = nil
                try context.save()
                throw error
            }
        }

        if quarantinedCount > 0 {
            throw QuarantinedReviewError(count: quarantinedCount)
        }
    }

    private func flushCardOutbox() async throws {
        if let cardOutboxFlushTask {
            return try await cardOutboxFlushTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await drainCardOutbox()
        }
        cardOutboxFlushTask = task
        do {
            try await task.value
            cardOutboxFlushTask = nil
        } catch {
            cardOutboxFlushTask = nil
            throw error
        }
    }

    private func drainCardOutbox() async throws {
        var quarantinedCount = 0
        let activeCardOrder = cards.map { $0.id.lowercased() }
        defer {
            // Reconciliation can rename or remove records. Refresh once after
            // the drain instead of decoding the entire library after every
            // queued mutation in a large offline backlog. Preserve the active
            // array's current order so background sync cannot replace the card
            // at the front of an in-progress session.
            loadLocalCards(preservingNormalizedOrder: activeCardOrder)
            loadLibraryCards()
        }
        while true {
            var descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    ($0.kind == "cardCreate"
                        || $0.kind == "cardUpdate"
                        || $0.kind == "cardDelete")
                        && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            descriptor.fetchLimit = 1
            guard let mutation = try context.fetch(descriptor).first else {
                if quarantinedCount > 0 {
                    throw QuarantinedCardError(count: quarantinedCount)
                }
                return
            }

            do {
                let clientResourceID = mutation.resourceID
                let serverCard: StudyCard?
                switch mutation.kind {
                case "cardCreate":
                    let request = try StorageCodec.decoder.decode(
                        CreateStudyCardRequest.self,
                        from: mutation.payload
                    )
                    // The ConvoLab-compatible /api/study/cards mutations intentionally return
                    // StudyCardSummaryResource directly (without Laravel's `data` envelope).
                    serverCard = try await api.request(
                        "/api/study/cards",
                        method: "POST",
                        body: request
                    )
                case "cardUpdate":
                    let request = try StorageCodec.decoder.decode(
                        UpdateStudyCardRequest.self,
                        from: mutation.payload
                    )
                    serverCard = try await api.request(
                        "/api/study/cards/\(mutation.resourceID)",
                        method: "PATCH",
                        body: request
                    )
                case "cardDelete":
                    let _: IgnoredResponse = try await api.request(
                        "/api/study/cards/\(mutation.resourceID)",
                        method: "DELETE"
                    )
                    serverCard = nil
                default:
                    return
                }

                if mutation.kind == "cardCreate", let serverCard {
                    try reconcileCreatedCardID(
                        from: clientResourceID,
                        to: serverCard.id
                    )
                }
                if let serverCard, try !hasPendingDelete(for: serverCard.id) {
                    let preservesPendingEdit = try hasPendingUpdate(
                        for: serverCard.id,
                        excluding: mutation.id
                    )
                    let acknowledgedCard = try acknowledgedCard(
                        serverCard,
                        preservingPendingReview: hasPendingReview(for: serverCard.id),
                        preservingPendingEdit: preservesPendingEdit
                    )
                    try updateLocalCard(
                        acknowledgedCard,
                        markedDirty: preservesPendingEdit,
                        serverUpdatedAt: serverCard.updatedAt
                    )
                }
                context.delete(mutation)
                try context.save()
            } catch let APIClientError.rejected(status, _)
                where mutation.kind == "cardDelete" && status == 404
            {
                // A missing server record satisfies an idempotent delete.
                context.delete(mutation)
                try context.save()
            } catch let APIClientError.rejected(status, message)
                where [400, 404, 409, 410, 422].contains(status)
            {
                mutation.attemptCount += 1
                mutation.lastAttemptAt = .now
                mutation.lastError = "HTTP \(status): \(message)"
                try context.save()
                quarantinedCount += 1
            } catch {
                mutation.attemptCount += 1
                mutation.lastAttemptAt = .now
                mutation.lastError = nil
                try context.save()
                throw error
            }
        }
    }

    private func reconcileCreatedCardID(from clientID: String, to serverID: String) throws {
        guard clientID != serverID else { return }

        var clientDescriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == clientID }
        )
        clientDescriptor.fetchLimit = 1
        var serverDescriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == serverID }
        )
        serverDescriptor.fetchLimit = 1
        let clientRecord = try context.fetch(clientDescriptor).first
        let serverRecord = try context.fetch(serverDescriptor).first
        let mutationDescriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.resourceID == clientID || $0.resourceID == serverID
            }
        )
        let aliasMutations = try context.fetch(mutationDescriptor)
        if let clientRecord {
            if let serverRecord, serverRecord !== clientRecord {
                let clientHasPendingActivity = aliasMutations.contains {
                    $0.resourceID == clientID && $0.kind != "cardCreate"
                }
                let serverHasPendingActivity = aliasMutations.contains {
                    $0.resourceID == serverID && $0.kind != "cardCreate"
                }
                let preferServerRecord = if
                    clientHasPendingActivity != serverHasPendingActivity
                {
                    serverHasPendingActivity
                } else {
                    localActivityDate(for: serverRecord) > localActivityDate(for: clientRecord)
                }
                if preferServerRecord {
                    context.delete(clientRecord)
                } else {
                    context.delete(serverRecord)
                    try context.save()
                    clientRecord.id = serverID
                }
                try context.save()
            } else {
                clientRecord.id = serverID
            }
        }

        for pending in aliasMutations
        where pending.resourceID == clientID && pending.kind != "cardCreate" {
            pending.resourceID = serverID
            guard
                pending.kind == "review",
                let decoded = try? decodePendingReview(pending.payload),
                let cardBefore = decoded.cardBefore
            else {
                continue
            }
            let event = decoded.event
            let canonicalEvent = ReviewBatchRequest.Event(
                id: event.id,
                cardID: serverID,
                rating: event.rating,
                reviewedAt: event.reviewedAt,
                durationMilliseconds: event.durationMilliseconds,
                clientEventID: event.clientEventID,
                deviceID: event.deviceID,
                clientCreatedAt: event.clientCreatedAt
            )
            pending.payload = try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: canonicalEvent,
                    cardBefore: PendingReviewCardState(
                        id: serverID,
                        failedAt: cardBefore.failedAt
                    )
                )
            )
        }
    }

    private func localActivityDate(for record: LocalCardRecord) -> Date {
        let cardUpdatedAt = (try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        ))?.updatedAt ?? .distantPast
        return max(record.locallyUpdatedAt ?? .distantPast, cardUpdatedAt)
    }

    private func hasPendingDelete(for cardID: String) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "cardDelete" && $0.resourceID == cardID
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func hasPendingCreate(for cardID: String) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "cardCreate"
                    && $0.resourceID == cardID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func hasPendingReview(for cardID: String) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "review"
                    && $0.resourceID == cardID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func hasPendingUpdate(
        for cardID: String,
        excluding mutationID: String
    ) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "cardUpdate"
                    && $0.resourceID == cardID
                    && $0.id != mutationID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func restorePendingReviewState() {
        guard let state = try? pendingReviewState() else { return }
        apply(state)
    }

    private func apply(_ state: PendingReviewState) {
        newlyFailedCardIDs = state.newlyFailedCardIDs
        retainedFailedCardIDs = state.retainedFailedCardIDs
        resolvedFailedCardIDs = state.resolvedFailedCardIDs
    }

    private func pendingReviewState() throws -> PendingReviewState {
        let pending = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.kind == "review" && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
        let pendingCardIDs = pending.map(\.resourceID)
        let records = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { pendingCardIDs.contains($0.id) }
            )
        )
        let cardsByID = Dictionary(
            records.compactMap { record in
                (try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload))
                    .map { ($0.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var state = PendingReviewState()

        for mutation in pending {
            state.cardIDs.insert(mutation.resourceID)
        }
        let decodedPending = pending.compactMap { mutation in
            (try? decodePendingReview(mutation.payload)).map { (mutation, $0) }
        }
        .sorted { left, right in
            if left.1.event.reviewedAt != right.1.event.reviewedAt {
                return left.1.event.reviewedAt < right.1.event.reviewedAt
            }
            return left.1.event.id < right.1.event.id
        }

        for (mutation, decoded) in decodedPending {
            guard let card = decoded.cardBefore
                ?? cardsByID[mutation.resourceID].map(PendingReviewCardState.init)
            else {
                continue
            }
            state.record(card: card, rating: decoded.event.rating)
        }
        return state
    }

    private func decodePendingReview(
        _ payload: Data
    ) throws -> (event: ReviewBatchRequest.Event, cardBefore: PendingReviewCardState?) {
        if let legacy = try? StorageCodec.decoder.decode(
            LegacyPendingReviewPayload.self,
            from: payload
        ) {
            return (legacy.event, PendingReviewCardState(card: legacy.cardBefore))
        }
        if let wrapped = try? StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: payload
        ) {
            return (wrapped.event, wrapped.cardBefore)
        }
        return (
            try StorageCodec.decoder.decode(ReviewBatchRequest.Event.self, from: payload),
            nil
        )
    }

    private func persist(cards: [StudyCard]) throws {
        let existing = try context.fetch(FetchDescriptor<LocalCardRecord>())
        existing.forEach { $0.isInActiveSession = false }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for (index, card) in cards.enumerated() {
            let payload = try StorageCodec.encoder.encode(card)
            if let record = byID[card.id] {
                record.isInActiveSession = true
                guard record.locallyUpdatedAt == nil else { continue }
                record.payload = payload
                record.queueIndex = index
                record.serverUpdatedAt = card.updatedAt
            } else {
                context.insert(LocalCardRecord(card: card, queueIndex: index, payload: payload))
            }
        }
        try context.save()
    }

    private func markPrepared(cards: [StudyCard]) {
        let cardsByID = Dictionary(
            cards.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let cachedKeys = mediaCache.cachedKeys(for: cards.flatMap(\.mediaURLs))
        let records = (try? context.fetch(FetchDescriptor<LocalCardRecord>())) ?? []
        for record in records {
            guard let card = cardsByID[record.id] else { continue }
            let isPrepared = card.mediaURLs.allSatisfy {
                cachedKeys.contains(MediaCache.stableCacheKey(for: $0))
            }
            record.mediaPreparedAt = isPrepared ? .now : nil
        }
        try? context.save()
    }

    private func acknowledgedCard(
        _ serverCard: StudyCard,
        preservingPendingReview: Bool,
        preservingPendingEdit: Bool
    ) throws -> StudyCard {
        guard preservingPendingReview || preservingPendingEdit else { return serverCard }

        let cardID = serverCard.id
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        descriptor.fetchLimit = 1
        guard
            let record = try context.fetch(descriptor).first,
            let localCard = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            )
        else {
            return serverCard
        }

        return StudyCard(
            id: serverCard.id,
            syncId: serverCard.syncId ?? localCard.syncId,
            noteId: serverCard.noteId,
            cardType: serverCard.cardType,
            prompt: preservingPendingEdit ? localCard.prompt : serverCard.prompt,
            answer: preservingPendingEdit ? localCard.answer : serverCard.answer,
            state: preservingPendingReview ? localCard.state : serverCard.state,
            answerAudioSource: serverCard.answerAudioSource,
            createdAt: serverCard.createdAt,
            updatedAt: preservingPendingReview || preservingPendingEdit
                ? localCard.updatedAt
                : serverCard.updatedAt
        )
    }

    private func currentLocalCard(for card: StudyCard) throws -> StudyCard {
        let cardID = card.id
        var exactDescriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        exactDescriptor.fetchLimit = 1
        if
            let record = try context.fetch(exactDescriptor).first,
            let current = try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        {
            return current
        }

        // learning-os canonicalizes client-generated ULIDs to lowercase. An editor
        // can still hold the original snapshot while background sync renames the
        // persisted record, so resolve that alias before saving.
        let normalizedID = card.id.lowercased()
        if
            let record = try context.fetch(FetchDescriptor<LocalCardRecord>()).first(
                where: { $0.id.lowercased() == normalizedID }
            ),
            let current = try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        {
            return current
        }

        throw MissingLocalCardError()
    }

    private func updateLocalCard(
        _ card: StudyCard,
        markedDirty: Bool,
        serverUpdatedAt: Date? = nil
    ) throws {
        let cardID = card.id
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        descriptor.fetchLimit = 1
        let payload = try StorageCodec.encoder.encode(card)
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
            record.serverUpdatedAt = serverUpdatedAt ?? card.updatedAt
            record.locallyUpdatedAt = markedDirty ? .now : nil
        } else {
            let record = LocalCardRecord(card: card, queueIndex: cards.count, payload: payload)
            record.serverUpdatedAt = serverUpdatedAt ?? card.updatedAt
            record.locallyUpdatedAt = markedDirty ? .now : nil
            context.insert(record)
        }
    }

    private func loadLocalCards() {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.isInActiveSession },
            sortBy: [SortDescriptor(\.queueIndex)]
        )
        cards = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
        cards = Self.orderSessionCards(cards)
    }

    private func loadLocalCards(preservingNormalizedOrder order: [String]) {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.isInActiveSession },
            sortBy: [SortDescriptor(\.queueIndex)]
        )
        var persistedByNormalizedID = Dictionary(
            ((try? context.fetch(descriptor)) ?? []).compactMap { record in
                try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
            }.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let preserved = order.compactMap { persistedByNormalizedID.removeValue(forKey: $0) }
        cards = preserved + Self.orderSessionCards(Array(persistedByNormalizedID.values))
    }

    private func loadLibraryCards() {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            sortBy: [SortDescriptor(\.serverUpdatedAt, order: .reverse)]
        )
        libraryCards = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
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

    private func synchronizeWaniKani(userID: Int) async throws {
        guard activeUserID == userID else { return }
        let _: WaniKaniSyncResult = try await api.request(
            "/api/study/wanikani/sync",
            method: "POST"
        )
        guard activeUserID == userID else { return }
        try await refreshKnownKanji()
    }

    private func apply(_ snapshot: KnownKanjiSnapshot, userID: Int) throws {
        guard activeUserID == userID else { return }
        guard snapshot.version >= knownKanjiVersion else { return }
        let payload = try StorageCodec.encoder.encode(snapshot)
        var descriptor = FetchDescriptor<LocalKnownKanjiSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
            record.updatedAt = .now
        } else {
            context.insert(LocalKnownKanjiSnapshot(userID: userID, payload: payload))
        }
        try context.save()
        present(snapshot)
    }

    private func loadKnownKanji(userID: Int) {
        var descriptor = FetchDescriptor<LocalKnownKanjiSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard
            let record = try? context.fetch(descriptor).first,
            let snapshot = try? StorageCodec.decoder.decode(
                KnownKanjiSnapshot.self,
                from: record.payload
            )
        else {
            present(nil)
            return
        }
        present(snapshot)
    }

    private func present(_ snapshot: KnownKanjiSnapshot?) {
        knownKanji = Set(snapshot?.kanji.compactMap(\.singleCharacter) ?? [])
        manualKnownKanji = Set(snapshot?.manualKanji.compactMap(\.singleCharacter) ?? [])
        knownKanjiVersion = snapshot?.version ?? -1
        wanikaniConnected = snapshot?.wanikani.connected ?? false
        wanikaniLastSyncedAt = snapshot?.wanikani.lastSyncedAt
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

    private static func orderSessionCards(_ cards: [StudyCard]) -> [StudyCard] {
        cards.enumerated().sorted { leftEntry, rightEntry in
            let left = leftEntry.element
            let right = rightEntry.element
            let leftIsNew = left.state.queueState == "new"
            let rightIsNew = right.state.queueState == "new"
            if leftIsNew != rightIsNew {
                return !leftIsNew
            }
            if leftIsNew {
                return leftEntry.offset < rightEntry.offset
            }
            let leftDueAt = left.state.dueAt ?? .distantFuture
            let rightDueAt = right.state.dueAt ?? .distantFuture
            if leftDueAt != rightDueAt {
                return leftDueAt < rightDueAt
            }
            if left.id != right.id {
                return left.id < right.id
            }
            return leftEntry.offset < rightEntry.offset
        }
        .map(\.element)
    }
}

struct StudySessionCounts: Equatable {
    let failedDue: Int
    let reviewRemaining: Int
    let newRemaining: Int

    static func calculate(
        cards: [StudyCard],
        overview: StudyOverview?,
        newlyFailedCardIDs: Set<String> = [],
        retainedFailedCardIDs: Set<String> = [],
        resolvedFailedCardIDs: Set<String> = []
    ) -> StudySessionCounts {
        let loadedFailedCardIDs = Set(
            cards.lazy.filter { $0.state.failedAt != nil }.map(\.id)
        )
        let authoritativeFailedCount = max(
            0,
            (overview?.failedCount ?? 0) - resolvedFailedCardIDs.count
        )
        let pendingFailedCardIDs = retainedFailedCardIDs.union(newlyFailedCardIDs)
        let localFailedCount = loadedFailedCardIDs.union(pendingFailedCardIDs).count
        let newRemaining = cards.count(where: {
            $0.state.failedAt == nil && $0.state.queueState == "new"
        })
        let reviewRemaining = cards.count(where: {
            $0.state.failedAt == nil && $0.state.queueState != "new"
        })

        return StudySessionCounts(
            failedDue: max(
                authoritativeFailedCount + newlyFailedCardIDs.count,
                localFailedCount
            ),
            reviewRemaining: reviewRemaining,
            newRemaining: newRemaining
        )
    }
}

private extension String {
    var singleCharacter: Character? {
        count == 1 ? first : nil
    }
}

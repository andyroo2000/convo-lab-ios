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

    private struct MissingGeneratedAudioError: LocalizedError {
        var errorDescription: String? {
            "The server regenerated this card without returning playable audio."
        }
    }

    private struct MissingGeneratedImageError: LocalizedError {
        var errorDescription: String? {
            "The server regenerated this card without returning a usable image."
        }
    }

    private struct MismatchedGeneratedImagesError: LocalizedError {
        var errorDescription: String? {
            "The server returned different front and back images for a shared-image request."
        }
    }

    private struct InvalidImagePromptError: LocalizedError {
        var errorDescription: String? {
            "Enter a non-empty image prompt no longer than 1,000 characters."
        }
    }

    private struct InvalidImagePlacementError: LocalizedError {
        var errorDescription: String? {
            "Choose Front, Back, or Front and back before regenerating an image."
        }
    }

    private struct PendingCardChangesError: LocalizedError {
        let medium: String

        var errorDescription: String? {
            "Sync this card’s pending changes before regenerating its \(medium)."
        }
    }

    private struct PendingDraftCommitError: LocalizedError {
        var errorDescription: String? {
            "This draft may already have created a card. Retry Create Card or sync before deleting it."
        }
    }

    struct AnswerAudioRegenerationResult {
        let card: StudyCard
        let localURL: URL
    }

    struct ImageRegenerationResult {
        let card: StudyCard
        let localURL: URL
    }

    struct DraftPreviewAudioResult {
        let draft: StudyManualCardDraft
        let localURL: URL?
    }

    struct DraftPreviewImageResult {
        let draft: StudyManualCardDraft
        let localURL: URL
    }

    enum DraftCommitRecoveryState: Equatable {
        case none
        case rejected
        case outcomeUnknown
        case cleanupPending
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
    @ObservationIgnored private var draftCreateTasks: [String: Task<StudyManualCardDraft, Error>] = [:]
    @ObservationIgnored private var draftCommitTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var manualDraftRefreshTask: Task<Void, Error>?
    @ObservationIgnored private var manualDraftRevision = 0
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var newlyFailedCardIDs: Set<String> = []
    @ObservationIgnored private var retainedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var resolvedFailedCardIDs: Set<String> = []
    @ObservationIgnored private var offlineDueActivationTimer: Timer?

    private(set) var cards: [StudyCard] = []
    private(set) var libraryCards: [StudyCard] = []
    private(set) var manualDrafts: [StudyManualCardDraft] = []
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
            try await retryPendingDraftCreates()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await retryPendingDraftCommits()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await flushReviewOutbox()
        } catch {
            firstError = firstError ?? error
        }
        // Fetch small, user-visible metadata before session media preparation
        // consumes the shared production request bucket.
        if activeUserID != nil {
            do {
                try await refreshKnownKanji()
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            try await refreshSession()
            refreshed = true
        } catch {
            firstError = firstError ?? error
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
        let response: StudySessionResponse = try await api.request(
            "/api/study/session/start",
            method: "POST",
            body: ["time_zone": timeZone]
        )
        let session = response.session
        let pendingReviewState = try pendingReviewState()
        var seenCardIDs: Set<String> = []
        let activeCards = Self.orderSessionCards(try session.cards.filter { card in
            try !hasPendingDelete(for: card.id)
                && !pendingReviewState.cardIDs.contains(card.id)
                && seenCardIDs.insert(card.id).inserted
        })
        overview = session.overview
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

    func refreshManualDrafts() async throws {
        if let manualDraftRefreshTask {
            return try await manualDraftRefreshTask.value
        }
        let startingRevision = manualDraftRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let drafts = try await fetchAllManualDrafts()
            guard manualDraftRevision == startingRevision else { return }
            manualDrafts = drafts
        }
        manualDraftRefreshTask = task
        defer { manualDraftRefreshTask = nil }
        try await task.value
    }

    private func fetchAllManualDrafts() async throws -> [StudyManualCardDraft] {
        var drafts: [StudyManualCardDraft] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: StudyManualCardDraftListResponse = try await api.request(
                "/api/study/card-drafts",
                query: query
            )
            drafts.append(contentsOf: response.drafts)
            cursor = response.nextCursor
            if let nextCursor = cursor, !seenCursors.insert(nextCursor).inserted {
                cursor = nil
            }
        } while cursor != nil
        return drafts
    }

    @discardableResult
    func queueManualDraft(
        creationKind: StudyCardCreationKind,
        draft: StudyCardDraft,
        id: String = ClientIdentifier.ulid()
    ) async throws -> StudyManualCardDraft {
        let request = CreateStudyManualCardDraftRequest(
            id: id,
            creationKind: creationKind,
            cardType: creationKind.cardType.rawValue,
            prompt: creationKind == .audioRecognition ? .object([:]) : draft.prompt(),
            answer: draft.answer(),
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty
        )
        let mutation: PendingMutation
        if let existing = try pendingDraftCreate(for: id) {
            mutation = existing
        } else {
            mutation = PendingMutation(
                kind: "draftCreate",
                resourceID: id,
                payload: try StorageCodec.encoder.encode(request)
            )
            context.insert(mutation)
            try context.save()
        }
        return try await runDraftCreate(mutation)
    }

    @discardableResult
    func updateManualDraft(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue? = nil,
        previewAudioRole: String? = nil,
        previewImage: JSONValue? = nil
    ) async throws -> StudyManualCardDraft {
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
        let request = UpdateStudyManualCardDraftRequest(
            prompt: prompt,
            answer: answer,
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty,
            previewAudio: previewAudio ?? .null,
            previewAudioRole: previewAudioRole.map(JSONValue.string) ?? .null,
            previewImage: previewImage ?? .null
        )
        let updated: StudyManualCardDraft = try await api.request(
            "/api/study/card-drafts/\(serverDraft.id)",
            method: "PATCH",
            body: request
        )
        replaceManualDraft(updated)
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
            throw MissingGeneratedImageError()
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
        let existingCommit = try pendingDraftCommit(for: serverDraft.id)
        let shouldUpdateDraft = existingCommit == nil
            || existingCommit?.kind == "draftCommitRejected"
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
        let commitMutation: PendingMutation
        if let existingCommit {
            commitMutation = existingCommit
        } else if let pending = try pendingDraftCommit(for: updated.id) {
            commitMutation = pending
        } else {
            let request = CreateCardFromStudyManualDraftRequest(id: ClientIdentifier.ulid())
            commitMutation = PendingMutation(
                kind: "draftCommit",
                resourceID: updated.id,
                payload: try StorageCodec.encoder.encode(request)
            )
            context.insert(commitMutation)
            try context.save()
        }
        if commitMutation.kind == "draftCommitRejected" {
            commitMutation.kind = "draftCommit"
            commitMutation.attemptCount = 0
            commitMutation.lastAttemptAt = nil
            commitMutation.lastError = nil
            try context.save()
        }
        try await runDraftCommit(commitMutation)
    }

    func deleteManualDraft(_ serverDraft: StudyManualCardDraft) async throws {
        let pendingCommit = try pendingDraftCommit(for: serverDraft.id)
        if let pendingCommit, pendingCommit.kind != "draftCommitRejected" {
            throw PendingDraftCommitError()
        }
        let _: IgnoredResponse = try await api.request(
            "/api/study/card-drafts/\(serverDraft.id)",
            method: "DELETE"
        )
        if let pendingCommit {
            context.delete(pendingCommit)
            try context.save()
        }
        manualDrafts.removeAll { $0.id == serverDraft.id }
        manualDraftRevision += 1
    }

    func hasPendingDraftCommit(for draftID: String) -> Bool {
        draftCommitRecoveryState(for: draftID) != .none
    }

    func draftCommitRecoveryState(for draftID: String) -> DraftCommitRecoveryState {
        guard
            let mutation = try? pendingDraftCommit(for: draftID),
            let request = try? StorageCodec.decoder.decode(
                CreateCardFromStudyManualDraftRequest.self,
                from: mutation.payload
            )
        else {
            return .none
        }
        if mutation.kind == "draftCommitRejected" {
            return .rejected
        }
        let originalCardID = request.id
        let normalizedCardID = request.id.lowercased()
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate {
                $0.id == normalizedCardID || $0.id == originalCardID
            }
        )
        descriptor.fetchLimit = 1
        let hasConfirmedLocalCard = ((try? context.fetch(descriptor)) ?? []).isEmpty == false
        return hasConfirmedLocalCard ? .cleanupPending : .outcomeUnknown
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

    func regenerateAnswerAudio(
        for card: StudyCard,
        voiceID: String,
        textOverride: String
    ) async throws -> AnswerAudioRegenerationResult {
        do {
            try await flushCardOutbox()
        } catch is QuarantinedCardError {
            // A rejected write for another card should not block this generated
            // media action. The per-card guard below still blocks when this
            // card itself owns the unresolved write.
        }
        let currentCard = try currentLocalCard(for: card)
        guard try !hasPendingCardWrite(for: currentCard.id) else {
            throw PendingCardChangesError(medium: "audio")
        }
        let request = RegenerateAnswerAudioRequest(
            answerAudioVoiceId: voiceID.nilIfTrimmedEmpty,
            answerAudioTextOverride: textOverride.nilIfTrimmedEmpty
        )
        // learning-os compatibility endpoint returns the card directly, without
        // the data envelope used by newer API endpoints.
        let serverCard: StudyCard = try await api.request(
            "/api/study/cards/\(currentCard.reviewCardID)/regenerate-answer-audio",
            method: "POST",
            body: request,
            timeout: 180
        )
        guard
            let generatedAudio = serverCard.answer["answerAudio"],
            let remoteURL = serverCard.answerAudioURL
        else {
            throw MissingGeneratedAudioError()
        }
        let localURL = try await mediaCache.refresh(
            remoteURL,
            category: "active-study"
        )
        // Once the server and cache have changed, always reconcile local card
        // metadata even if the editor that initiated the request was dismissed.
        let latestCard = try currentLocalCard(for: currentCard)
        let pendingCardWrite = try hasPendingCardWrite(for: latestCard.id)
        let updatedCard = StudyCard(
            id: latestCard.id,
            syncId: serverCard.syncId ?? latestCard.syncId,
            noteId: serverCard.noteId ?? latestCard.noteId,
            cardType: latestCard.cardType,
            prompt: latestCard.prompt,
            answer: latestCard.answer.replacingObjectValues([
                "answerAudio": generatedAudio,
                "answerAudioVoiceId": serverCard.answer["answerAudioVoiceId"]
                    ?? request.answerAudioVoiceId.map(JSONValue.string)
                    ?? .null,
                "answerAudioTextOverride": serverCard.answer["answerAudioTextOverride"]
                    ?? request.answerAudioTextOverride.map(JSONValue.string)
                    ?? .null,
            ]),
            state: latestCard.state,
            answerAudioSource: serverCard.answerAudioSource
                ?? latestCard.answerAudioSource,
            createdAt: latestCard.createdAt,
            updatedAt: max(latestCard.updatedAt, serverCard.updatedAt)
        )
        try updateLocalCard(
            updatedCard,
            markedDirty: pendingCardWrite,
            serverUpdatedAt: max(latestCard.updatedAt, serverCard.updatedAt)
        )
        cards = cards.map { $0.id == latestCard.id ? updatedCard : $0 }
        libraryCards = libraryCards.map { $0.id == latestCard.id ? updatedCard : $0 }
        try context.save()
        return AnswerAudioRegenerationResult(card: updatedCard, localURL: localURL)
    }

    func regenerateImage(
        for card: StudyCard,
        prompt: String,
        placement: StudyCardDraft.ImagePlacement
    ) async throws -> ImageRegenerationResult {
        let imagePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !imagePrompt.isEmpty,
            imagePrompt.count <= 1_000
        else {
            throw InvalidImagePromptError()
        }
        guard placement != .none else {
            throw InvalidImagePlacementError()
        }
        do {
            try await flushCardOutbox()
        } catch is QuarantinedCardError {
            // Rejected writes for other cards do not block this card's media.
        }
        let currentCard = try currentLocalCard(for: card)
        guard try !hasPendingCardWrite(for: currentCard.id) else {
            throw PendingCardChangesError(medium: "image")
        }
        let request = RegenerateImageRequest(
            imagePrompt: imagePrompt,
            imageRole: placement.rawValue
        )
        // learning-os compatibility endpoint returns the card directly.
        let serverCard: StudyCard = try await api.request(
            "/api/study/cards/\(currentCard.reviewCardID)/regenerate-image",
            method: "POST",
            body: request,
            timeout: 180
        )
        if
            placement == .both,
            let promptImage = serverCard.prompt["cueImage"],
            let answerImage = serverCard.answer["answerImage"],
            !promptImage.mediaURLs.isEmpty,
            !answerImage.mediaURLs.isEmpty,
            Set(promptImage.mediaURLs.map(MediaCache.stableCacheKey(for:)))
                != Set(answerImage.mediaURLs.map(MediaCache.stableCacheKey(for:)))
        {
            throw MismatchedGeneratedImagesError()
        }
        let generatedImageCandidates = placement == .answer
            ? [serverCard.answer["answerImage"], serverCard.prompt["cueImage"]]
            : [serverCard.prompt["cueImage"], serverCard.answer["answerImage"]]
        let generatedImage = generatedImageCandidates
            .compactMap(\.self)
            .first { !$0.mediaURLs.isEmpty }
        guard let generatedImage, let remoteURL = generatedImage.mediaURLs.first else {
            throw MissingGeneratedImageError()
        }
        let localURL = try await mediaCache.refresh(
            remoteURL,
            category: "active-study"
        )

        // As with audio, complete reconciliation after server/cache side effects
        // even if the editor has since been dismissed.
        let latestCard = try currentLocalCard(for: currentCard)
        let pendingCardWrite = try hasPendingCardWrite(for: latestCard.id)
        let latestPromptImage = latestCard.prompt["cueImage"]
        let latestAnswerImage = latestCard.answer["answerImage"]
        let promptImage: JSONValue = if placement.includesPrompt {
            generatedImage
        } else if latestPromptImage != currentCard.prompt["cueImage"] {
            latestPromptImage ?? .null
        } else {
            .null
        }
        let answerImage: JSONValue = if placement.includesAnswer {
            generatedImage
        } else if latestAnswerImage != currentCard.answer["answerImage"] {
            latestAnswerImage ?? .null
        } else {
            .null
        }
        let updatedCard = StudyCard(
            id: latestCard.id,
            syncId: serverCard.syncId ?? latestCard.syncId,
            noteId: serverCard.noteId ?? latestCard.noteId,
            cardType: latestCard.cardType,
            prompt: latestCard.prompt.replacingObjectValues([
                "cueImage": promptImage,
            ]),
            answer: latestCard.answer.replacingObjectValues([
                "answerImage": answerImage,
            ]),
            state: latestCard.state,
            // Image generation does not mutate answer audio. Preserve the
            // freshest local value rather than trusting a lean/stale projection.
            answerAudioSource: latestCard.answerAudioSource,
            createdAt: latestCard.createdAt,
            updatedAt: max(latestCard.updatedAt, serverCard.updatedAt)
        )
        try updateLocalCard(
            updatedCard,
            markedDirty: pendingCardWrite,
            serverUpdatedAt: max(latestCard.updatedAt, serverCard.updatedAt)
        )
        cards = cards.map { $0.id == latestCard.id ? updatedCard : $0 }
        libraryCards = libraryCards.map { $0.id == latestCard.id ? updatedCard : $0 }
        try context.save()
        return ImageRegenerationResult(card: updatedCard, localURL: localURL)
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

    private func hasPendingCardWrite(for cardID: String) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                ($0.kind == "cardCreate" || $0.kind == "cardUpdate")
                    && $0.resourceID == cardID
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

    private func fetchManualDraft(id: String) async throws -> StudyManualCardDraft {
        let draft: StudyManualCardDraft = try await api.request(
            "/api/study/card-drafts/\(id)"
        )
        replaceManualDraft(draft)
        return draft
    }

    private func pendingDraftCommit(for draftID: String) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                ($0.kind == "draftCommit" || $0.kind == "draftCommitRejected")
                    && $0.resourceID == draftID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func pendingDraftCreate(for draftID: String) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "draftCreate" && $0.resourceID == draftID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func retryPendingDraftCreates() async throws {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.kind == "draftCreate" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var firstError: (any Error)?
        for mutation in try context.fetch(descriptor) {
            do {
                _ = try await runDraftCreate(mutation)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func runDraftCreate(
        _ mutation: PendingMutation
    ) async throws -> StudyManualCardDraft {
        let mutationID = mutation.id
        if let task = draftCreateTasks[mutationID] {
            return try await task.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await performDraftCreate(mutation)
        }
        draftCreateTasks[mutationID] = task
        defer { draftCreateTasks[mutationID] = nil }
        return try await task.value
    }

    private func performDraftCreate(
        _ mutation: PendingMutation
    ) async throws -> StudyManualCardDraft {
        let request = try StorageCodec.decoder.decode(
            CreateStudyManualCardDraftRequest.self,
            from: mutation.payload
        )
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        mutation.lastError = nil
        try context.save()

        let serverDraft: StudyManualCardDraft
        do {
            serverDraft = try await api.request(
                "/api/study/card-drafts",
                method: "POST",
                body: request
            )
        } catch {
            mutation.lastError = error.localizedDescription
            try? context.save()
            throw error
        }

        context.delete(mutation)
        try context.save()
        replaceManualDraft(serverDraft)
        return serverDraft
    }

    func retryPendingDraftCommits() async throws {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "draftCommit" && $0.lastError == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var firstError: (any Error)?
        for mutation in try context.fetch(descriptor) {
            do {
                try await runDraftCommit(mutation)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func runDraftCommit(_ mutation: PendingMutation) async throws {
        let mutationID = mutation.id
        if let task = draftCommitTasks[mutationID] {
            return try await task.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await performDraftCommit(mutation)
        }
        draftCommitTasks[mutationID] = task
        defer { draftCommitTasks[mutationID] = nil }
        try await task.value
    }

    private func performDraftCommit(_ mutation: PendingMutation) async throws {
        let request = try StorageCodec.decoder.decode(
            CreateCardFromStudyManualDraftRequest.self,
            from: mutation.payload
        )
        let card: StudyCard
        do {
            // learning-os deliberately exposes the unwrapped ConvoLab
            // compatibility payload for manual draft creation and commit.
            card = try await api.request(
                "/api/study/card-drafts/\(mutation.resourceID)/create-card",
                method: "POST",
                body: request
            )
        } catch let rejection as APIClientError {
            let isPermanentRejection: Bool
            if case let .rejected(status, _) = rejection, status == 409 {
                isPermanentRejection = await draftHasDifferentCommittedCardID(
                    draftID: mutation.resourceID,
                    clientCardID: request.id
                )
            } else if case let .rejected(status, _) = rejection {
                isPermanentRejection = isPermanentDraftCommitRejection(status: status)
            } else {
                isPermanentRejection = false
            }
            if isPermanentRejection {
                // learning-os returns 200 for a same-client-ID idempotent retry.
                // Resolve 409s from canonical draft state, not localized prose:
                // generating remains transient; a different committed ID is terminal.
                mutation.kind = "draftCommitRejected"
            }
            recordDraftCommitFailure(
                rejection,
                on: mutation,
                isPermanentRejection: isPermanentRejection
            )
            try context.save()
            throw rejection
        } catch {
            recordDraftCommitFailure(error, on: mutation)
            try context.save()
            throw error
        }

        // Reconcile the confirmed server card before cleaning up the transient
        // draft so an interrupted cleanup cannot lose the canonical card.
        try updateLocalCard(card, markedDirty: false)
        cards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        cards.append(card)
        cards = Self.orderSessionCards(cards)
        libraryCards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        libraryCards.append(card)
        try context.save()
        await mediaCache.prepare(urls: card.mediaURLs, category: "active-study")
        do {
            let _: IgnoredResponse = try await api.request(
                "/api/study/card-drafts/\(mutation.resourceID)",
                method: "DELETE"
            )
        } catch let APIClientError.rejected(status, _) where [404, 410].contains(status) {
            // Cleanup is idempotent: an already-absent transient draft is done.
        } catch {
            recordDraftCleanupFailure(on: mutation)
            try context.save()
            throw error
        }
        context.delete(mutation)
        manualDrafts.removeAll { $0.id == mutation.resourceID }
        manualDraftRevision += 1
        try context.save()
    }

    private func recordDraftCommitFailure(
        _ error: any Error,
        on mutation: PendingMutation,
        isPermanentRejection override: Bool? = nil
    ) {
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        let isPermanentRejection: Bool
        if let override {
            isPermanentRejection = override
        } else if case let APIClientError.rejected(status, _) = error {
            isPermanentRejection = isPermanentDraftCommitRejection(status: status)
        } else {
            isPermanentRejection = false
        }
        mutation.lastError = isPermanentRejection ? error.localizedDescription : nil
    }

    private func draftHasDifferentCommittedCardID(
        draftID: String,
        clientCardID: String
    ) async -> Bool {
        guard
            let draft: StudyManualCardDraft = try? await api.request(
                "/api/study/card-drafts/\(draftID)"
            )
        else {
            return false
        }
        replaceManualDraft(draft)
        guard let committedCardID = draft.committedCardId else { return false }
        return committedCardID.lowercased() != clientCardID.lowercased()
    }

    private func isPermanentDraftCommitRejection(status: Int) -> Bool {
        return [400, 404, 410, 422].contains(status)
    }

    private func recordDraftCleanupFailure(on mutation: PendingMutation) {
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        // The card is already canonical at this point. Every cleanup failure
        // remains eligible for background retry, regardless of HTTP status.
        mutation.lastError = nil
    }

    // Internal so concurrency tests can model a completed local mutation while
    // an older list request is still in flight.
    func replaceManualDraft(_ draft: StudyManualCardDraft) {
        manualDrafts.removeAll { $0.id == draft.id }
        manualDrafts.append(draft)
        manualDrafts.sort { $0.createdAt > $1.createdAt }
        manualDraftRevision += 1
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

private extension String {
    var nilIfTrimmedEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

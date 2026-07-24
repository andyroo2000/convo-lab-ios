import Foundation
import SwiftData

@Observable
final class StudyStore {
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
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncAt: Date?

    init(api: APIClient, context: ModelContext, mediaCache: MediaCache) {
        self.api = api
        self.context = context
        self.mediaCache = mediaCache
        deviceID = ClientIdentifier.deviceID()
        loadLocalCards()
        loadLibraryCards()
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        loadKnownKanji(userID: userID)
    }

    var fiveDayNewCardTarget: Int {
        (overview?.newCardsPerDay ?? 0) * 5
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
            try await flushReviewOutbox()
        } catch {
            firstError = error
        }
        do {
            try await flushCardOutbox()
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
        var seenCardIDs: Set<String> = []
        let activeCards = try envelope.data.cards.filter { card in
            try !hasPendingDelete(for: card.id)
                && seenCardIDs.insert(card.id).inserted
        }
        overview = envelope.data.overview
        cards = activeCards
        try persist(cards: activeCards)
        loadLibraryCards()

        let mediaURLs = activeCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-study")
        markPrepared(cards: activeCards)
    }

    func refreshKnownKanji() async throws {
        guard let activeUserID else { return }
        let snapshot: KnownKanjiSnapshot = try await api.request("/api/study/known-kanji")
        try apply(snapshot, userID: activeUserID)
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
        duration: Duration?
    ) async {
        let now = Date.now
        let event = ReviewBatchRequest.Event(
            id: ClientIdentifier.ulid(date: now),
            cardID: card.id,
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
            let payload = try StorageCodec.encoder.encode(event)
            context.insert(PendingMutation(kind: "review", resourceID: card.id, payload: payload))
            let cardID = card.id
            var descriptor = FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.id == cardID }
            )
            descriptor.fetchLimit = 1
            try context.fetch(descriptor).first?.isInActiveSession = false
            try context.save()
            cards.removeAll { $0.id == card.id }
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
        let id = ClientIdentifier.ulid()
        let prompt: JSONValue = .object([
            "cueText": .string(expression),
            "cueReading": reading.isEmpty ? .null : .string(reading),
        ])
        let answer: JSONValue = .object([
            "expression": .string(expression),
            "meaning": .string(meaning),
        ])
        let request = CreateStudyCardRequest(
            id: id,
            cardType: "recognition",
            prompt: prompt,
            answer: answer
        )
        let now = Date.now
        let optimistic = StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
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
        let promptPayload = card.prompt.replacingObjectValues([
            "cueText": .string(prompt),
            "cueReading": reading.isEmpty ? .null : .string(reading),
        ])
        let answerPayload = card.answer.replacingObjectValues([
            "expression": .string(prompt),
            "meaning": .string(answer),
        ])
        let request = UpdateStudyCardRequest(prompt: promptPayload, answer: answerPayload)
        let updated = StudyCard(
            id: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: promptPayload,
            answer: answerPayload,
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
        try updateLocalCard(updated, markedDirty: true)
        context.insert(PendingMutation(
            kind: "cardUpdate",
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(request)
        ))
        cards = cards.map { $0.id == card.id ? updated : $0 }
        libraryCards = libraryCards.map { $0.id == card.id ? updated : $0 }
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            handleSyncError(error)
        }
    }

    func deleteCard(_ card: StudyCard) async throws {
        context.insert(PendingMutation(kind: "cardDelete", resourceID: card.id, payload: Data()))
        let cardID = card.id
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        if let record = try context.fetch(descriptor).first {
            context.delete(record)
        }
        cards.removeAll { $0.id == card.id }
        libraryCards.removeAll { $0.id == card.id }
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
            let event = try StorageCodec.decoder.decode(
                ReviewBatchRequest.Event.self,
                from: mutation.payload
            )
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

                if let serverCard, try !hasPendingDelete(for: serverCard.id) {
                    try updateLocalCard(serverCard, markedDirty: false)
                    cards = cards.map { $0.id == serverCard.id ? serverCard : $0 }
                    libraryCards = libraryCards.map {
                        $0.id == serverCard.id ? serverCard : $0
                    }
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

    private func hasPendingDelete(for cardID: String) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.kind == "cardDelete" && $0.resourceID == cardID
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
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

    private func updateLocalCard(_ card: StudyCard, markedDirty: Bool) throws {
        let cardID = card.id
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.id == cardID }
        )
        descriptor.fetchLimit = 1
        let payload = try StorageCodec.encoder.encode(card)
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
            record.serverUpdatedAt = card.updatedAt
            record.locallyUpdatedAt = markedDirty ? .now : nil
        } else {
            let record = LocalCardRecord(card: card, queueIndex: cards.count, payload: payload)
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
    }

    private func loadLibraryCards() {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            sortBy: [SortDescriptor(\.serverUpdatedAt, order: .reverse)]
        )
        libraryCards = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
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
}

private extension String {
    var singleCharacter: Character? {
        count == 1 ? first : nil
    }
}

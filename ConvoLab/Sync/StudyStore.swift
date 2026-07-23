import Foundation
import SwiftData

@Observable
final class StudyStore {
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

    private(set) var cards: [StudyCard] = []
    private(set) var overview: StudyOverview?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncAt: Date?

    init(api: APIClient, context: ModelContext, mediaCache: MediaCache) {
        self.api = api
        self.context = context
        self.mediaCache = mediaCache
        deviceID = ClientIdentifier.deviceID()
        loadLocalCards()
    }

    var fiveDayNewCardTarget: Int {
        (overview?.newCardsPerDay ?? 0) * 5
    }

    var preparedCardCount: Int {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.mediaPreparedAt != nil }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func synchronize() async {
        guard syncStatus != .syncing else { return }
        syncStatus = .syncing
        do {
            try await flushReviewOutbox()
            try await flushCardOutbox()
            try await refreshSession()
            lastSyncAt = .now
            syncStatus = .idle
        } catch let error as URLError where [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
        ].contains(error.code) {
            syncStatus = .offline
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    func refreshSession() async throws {
        let timeZone = TimeZone.current.identifier
        let envelope: APIEnvelope<StudySession> = try await api.request(
            "/api/study/session/start",
            method: "POST",
            body: ["time_zone": timeZone]
        )
        overview = envelope.data.overview
        cards = envelope.data.cards
        try persist(cards: cards)

        let mediaURLs = cards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-study")
        markPrepared(cards: cards)
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
            durationMilliseconds: duration.map { Int($0.components.seconds * 1_000) },
            clientEventID: UUID().uuidString.lowercased(),
            deviceID: deviceID,
            clientCreatedAt: now
        )
        do {
            let payload = try StorageCodec.encoder.encode(event)
            context.insert(PendingMutation(kind: "review", resourceID: card.id, payload: payload))
            try context.save()
            cards.removeAll { $0.id == card.id }
            try await flushReviewOutbox()
        } catch {
            syncStatus = .offline
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
        try context.save()

        do {
            try await flushCardOutbox()
        } catch {
            syncStatus = .offline
        }
    }

    func updateCard(_ card: StudyCard, prompt: String, answer: String) async throws {
        let promptPayload: JSONValue = .object(["cueText": .string(prompt)])
        let answerPayload: JSONValue = .object([
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
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            syncStatus = .offline
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
        try context.save()
        do {
            try await flushCardOutbox()
        } catch {
            syncStatus = .offline
        }
    }

    private func flushReviewOutbox() async throws {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.kind == "review" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pending = try context.fetch(descriptor)
        guard !pending.isEmpty else { return }

        let events = try pending.map {
            try StorageCodec.decoder.decode(ReviewBatchRequest.Event.self, from: $0.payload)
        }
        let _: IgnoredResponse = try await api.request(
            "/api/card-review-events/batch",
            method: "POST",
            body: ReviewBatchRequest(events: events)
        )
        pending.forEach(context.delete)
        try context.save()
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
        while true {
            var descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.kind == "cardCreate"
                        || $0.kind == "cardUpdate"
                        || $0.kind == "cardDelete"
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            descriptor.fetchLimit = 1
            guard let mutation = try context.fetch(descriptor).first else {
                return
            }

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
            }
            context.delete(mutation)
            try context.save()
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
        let ids = Set(cards.map(\.id))
        let records = (try? context.fetch(FetchDescriptor<LocalCardRecord>())) ?? []
        records.filter { ids.contains($0.id) }.forEach { $0.mediaPreparedAt = .now }
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
}

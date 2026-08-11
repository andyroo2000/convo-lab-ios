import Foundation
import SwiftData

struct PendingReviewCardState: Codable {
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

struct PendingReviewPayload: Codable {
    let event: ReviewBatchRequest.Event
    let cardBefore: PendingReviewCardState
}

private struct LegacyPendingReviewPayload: Codable {
    let event: ReviewBatchRequest.Event
    let cardBefore: StudyCard
}

struct PendingReviewState {
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

struct QuarantinedReviewError: LocalizedError {
    let count: Int

    var errorDescription: String? {
        "\(count) review \(count == 1 ? "event was" : "events were") rejected and held for inspection."
    }
}

final class ReviewEventOutbox {
    private static let uploadBatchSize = 100

    private let api: APIClient
    private let context: ModelContext
    private var activeUserID: Int?
    private var flushTask: Task<Void, Error>?
    private var generation = 0

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        generation += 1
        flushTask?.cancel()
        flushTask = nil
        activeUserID = userID
    }

    func deactivate() {
        generation += 1
        flushTask?.cancel()
        flushTask = nil
        activeUserID = nil
    }

    @discardableResult
    func stageEnqueue(
        event: ReviewBatchRequest.Event,
        cardBefore: StudyCard
    ) throws -> PendingMutation {
        guard let userID = activeUserID else { throw CancellationError() }
        let payload = try StorageCodec.encoder.encode(
            PendingReviewPayload(
                event: event,
                cardBefore: PendingReviewCardState(card: cardBefore)
            )
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: userID,
            resourceID: cardBefore.id,
            payload: payload
        )
        context.insert(mutation)
        return mutation
    }

    func flush() async throws {
        if let flushTask {
            return try await flushTask.value
        }
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await drain(userID: userID, generation: operationGeneration)
        }
        flushTask = task
        defer {
            if generation == operationGeneration {
                flushTask = nil
            }
        }
        try await task.value
    }

    func waitForCurrentFlush() async {
        guard let flushTask else { return }
        _ = try? await flushTask.value
    }

    func pendingState() throws -> PendingReviewState {
        guard let userID = activeUserID else { return PendingReviewState() }
        let pending = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "review" && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
        let pendingCardIDs = pending.map(\.resourceID)
        let records = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && pendingCardIDs.contains($0.id)
                }
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
            (try? decode(mutation.payload)).map { (mutation, $0) }
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

    func hasPendingReview(for cardID: String) throws -> Bool {
        guard let userID = activeUserID else { return false }
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == "review"
                    && $0.resourceID == cardID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    func stageRemoval(eventID: String) throws -> Bool {
        guard let userID = activeUserID else { return false }
        guard let pending = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == userID && $0.kind == "review" }
            )
        ).first(where: {
            (try? decode($0.payload).event.id) == eventID
        }) else {
            return false
        }
        context.delete(pending)
        return true
    }

    func retarget(_ mutation: PendingMutation, cardID: String) throws {
        guard mutation.kind == "review", mutation.userID == activeUserID else { return }
        mutation.resourceID = cardID
        guard
            let decoded = try? decode(mutation.payload),
            let cardBefore = decoded.cardBefore
        else {
            return
        }
        let event = decoded.event
        let canonicalEvent = ReviewBatchRequest.Event(
            id: event.id,
            cardID: cardID,
            rating: event.rating,
            reviewedAt: event.reviewedAt,
            durationMilliseconds: event.durationMilliseconds,
            clientEventID: event.clientEventID,
            deviceID: event.deviceID,
            clientCreatedAt: event.clientCreatedAt
        )
        mutation.payload = try StorageCodec.encoder.encode(
            PendingReviewPayload(
                event: canonicalEvent,
                cardBefore: PendingReviewCardState(
                    id: cardID,
                    failedAt: cardBefore.failedAt
                )
            )
        )
    }

    private func drain(userID: Int, generation: Int) async throws {
        var quarantinedCount = 0
        while true {
            try ensureActive(userID: userID, generation: generation)
            let descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "review" && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            let pending = try context.fetch(descriptor)
            let ready = try pending.filter {
                try !hasPendingCardCreate(for: $0.resourceID, userID: userID)
            }
            let batch = Array(ready.prefix(Self.uploadBatchSize))
            guard !batch.isEmpty else { break }

            let events = try batch.map { try decode($0.payload).event }
            do {
                try await api.request(
                    "/api/card-review-events/batch",
                    method: "POST",
                    body: ReviewBatchRequest(events: events)
                )
                // A switch here deliberately leaves the event for an idempotent retry
                // under its original account, using the same event and client IDs.
                try ensureActive(userID: userID, generation: generation)
                batch.forEach(context.delete)
                try context.save()
            } catch let APIClientError.rejected(status, _)
                where [400, 404, 409, 410, 422].contains(status)
            {
                try ensureActive(userID: userID, generation: generation)
                for (mutation, event) in zip(batch, events) {
                    do {
                        try await api.request(
                            "/api/card-review-events/batch",
                            method: "POST",
                            body: ReviewBatchRequest(events: [event])
                        )
                        try ensureActive(userID: userID, generation: generation)
                        context.delete(mutation)
                        try context.save()
                    } catch let APIClientError.rejected(individualStatus, individualMessage)
                        where [400, 404, 409, 410, 422].contains(individualStatus)
                    {
                        try ensureActive(userID: userID, generation: generation)
                        mutation.attemptCount += 1
                        mutation.lastAttemptAt = .now
                        mutation.lastError = "HTTP \(individualStatus): \(individualMessage)"
                        try context.save()
                        quarantinedCount += 1
                    } catch {
                        try ensureActive(userID: userID, generation: generation)
                        mutation.attemptCount += 1
                        mutation.lastAttemptAt = .now
                        mutation.lastError = nil
                        try context.save()
                        throw error
                    }
                }
            } catch {
                try ensureActive(userID: userID, generation: generation)
                for mutation in batch {
                    mutation.attemptCount += 1
                    mutation.lastAttemptAt = .now
                    mutation.lastError = nil
                }
                try context.save()
                throw error
            }
        }

        if quarantinedCount > 0 {
            throw QuarantinedReviewError(count: quarantinedCount)
        }
    }

    private func ensureActive(userID: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard activeUserID == userID, self.generation == generation else {
            throw CancellationError()
        }
    }

    private func hasPendingCardCreate(for cardID: String, userID: Int) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == "cardCreate"
                    && $0.resourceID == cardID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func decode(
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
}

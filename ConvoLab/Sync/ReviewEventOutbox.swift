import Foundation
import SwiftData

struct PendingReviewCardState: Codable {
    let id: String
    let failedAt: Date?
    let queueState: String?

    init(card: StudyCard) {
        id = card.id
        failedAt = card.state.failedAt
        queueState = card.state.queueState
    }

    init(id: String, failedAt: Date?, queueState: String? = nil) {
        self.id = id
        self.failedAt = failedAt
        self.queueState = queueState
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
    var consumedOrdinary = 0
    var consumedNew = 0
    var unknownQueue = 0

    mutating func recordOriginalQueue(_ card: PendingReviewCardState?) {
        if card?.queueState == "new" {
            consumedNew += 1
        } else if card?.failedAt != nil {
            return
        } else if card?.queueState != nil {
            consumedOrdinary += 1
        } else {
            // Older compact payloads did not store their original queue.
            unknownQueue += 1
        }
    }

    var newlyFailedCardIDs: Set<String> = []
    var retainedFailedCardIDs: Set<String> = []
    var resolvedFailedCardIDs: Set<String> = []

    mutating func record(card: PendingReviewCardState, rating: ReviewRating) {
        guard rating == .again else {
            let wasNewlyFailed = newlyFailedCardIDs.remove(card.id) != nil
            retainedFailedCardIDs.remove(card.id)
            if card.failedAt != nil, !wasNewlyFailed {
                resolvedFailedCardIDs.insert(card.id)
            }
            return
        }
        let wasResolved = resolvedFailedCardIDs.remove(card.id) != nil
        if newlyFailedCardIDs.contains(card.id) {
            retainedFailedCardIDs.remove(card.id)
        } else if wasResolved || card.failedAt != nil {
            retainedFailedCardIDs.insert(card.id)
        } else {
            newlyFailedCardIDs.insert(card.id)
        }
    }
}

struct QuarantinedReviewError: LocalizedError {
    let count: Int

    var errorDescription: String? {
        "\(count) review \(count == 1 ? "event was" : "events were") rejected and held for inspection."
    }
}

struct ReviewEventFlushResult: Equatable {
    var progressionLockedEventIDs: Set<String> = []

    var isEmpty: Bool { progressionLockedEventIDs.isEmpty }

    mutating func formUnion(_ other: Self) {
        progressionLockedEventIDs.formUnion(other.progressionLockedEventIDs)
    }
}

struct ReviewEventFlushFailure: LocalizedError {
    let result: ReviewEventFlushResult
    let underlyingError: any Error

    var errorDescription: String? { underlyingError.localizedDescription }
}

final class ReviewEventOutbox {
    private static let uploadBatchSize = 100

    private let api: APIClient
    private let context: ModelContext
    private let localCardRepository: StudyCardLocalRepository
    private var activeUserID: Int?
    private var flushTask: Task<ReviewEventFlushResult, Error>?
    private var generation = 0

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
        localCardRepository = StudyCardLocalRepository(context: context)
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
        var latestDescriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && ($0.kind == "cardAction" || $0.kind == "review")
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        if let latestCreatedAt = try context.fetch(latestDescriptor).first?.createdAt,
           mutation.createdAt <= latestCreatedAt {
            mutation.createdAt = latestCreatedAt.addingTimeInterval(0.001)
        }
        context.insert(mutation)
        return mutation
    }

    @discardableResult
    func flush() async throws -> ReviewEventFlushResult {
        if let flushTask {
            return try await flushTask.value
        }
        guard let userID = activeUserID else { return ReviewEventFlushResult() }
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return ReviewEventFlushResult() }
            return try await drain(userID: userID, generation: operationGeneration)
        }
        flushTask = task
        defer {
            if generation == operationGeneration {
                flushTask = nil
            }
        }
        return try await task.value
    }

    func discardProgressionLockedFailures() throws -> ReviewEventFlushResult {
        guard let userID = activeUserID else { return ReviewEventFlushResult() }
        let failed = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "review" && $0.lastError != nil
                }
            )
        )
        var result = ReviewEventFlushResult()
        var discardedAny = false
        for mutation in failed where Self.isProgressionLockedFailure(mutation.lastError) {
            if let event = try? decode(mutation.payload).event {
                result.progressionLockedEventIDs.insert(event.id)
                try localCardRepository.markProgressionLocked(
                    matching: [mutation.resourceID, event.cardID],
                    userID: userID
                )
            }
            context.delete(mutation)
            discardedAny = true
        }
        if discardedAny {
            try context.save()
        }
        return result
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
        guard !pending.isEmpty else { return PendingReviewState() }
        var state = PendingReviewState()
        state.cardIDs = Set(pending.map(\.resourceID))
        let decodedPending = pending.compactMap { mutation in
            (try? decode(mutation.payload)).map { (mutation, $0) }
        }
        .sorted { left, right in
            if left.1.event.reviewedAt != right.1.event.reviewedAt {
                return left.1.event.reviewedAt < right.1.event.reviewedAt
            }
            return left.1.event.id < right.1.event.id
        }

        let legacyIDs = decodedPending.compactMap { mutation, decoded in
            decoded.cardBefore == nil ? mutation.resourceID : nil
        }
        let cardsByID = try legacyIDs.isEmpty ? [:] : legacyCards(for: legacyIDs, userID: userID)
        var countedIDs = Set<String>()
        for (mutation, decoded) in decodedPending {
            if countedIDs.insert(mutation.resourceID.lowercased()).inserted {
                state.recordOriginalQueue(decoded.cardBefore)
            }
            guard let card = decoded.cardBefore
                ?? cardsByID[mutation.resourceID].map(PendingReviewCardState.init)
            else {
                continue
            }
            state.record(card: card, rating: decoded.event.rating)
        }
        return state
    }

    private func legacyCards(for pendingCardIDs: [String], userID: Int) throws -> [String: StudyCard] {
        let records = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && pendingCardIDs.contains($0.id)
                }
            )
        )
        return Dictionary(
            records.compactMap { record in
                (try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload))
                    .map { ($0.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
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

    func pendingDeliverableCount() throws -> Int {
        guard let userID = activeUserID else { return 0 }
        return try context.fetchCount(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && $0.kind == "review"
                        && $0.lastError == nil
                }
            )
        )
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

    func cardID(for mutation: PendingMutation) -> String? {
        guard mutation.kind == "review", mutation.userID == activeUserID else {
            return nil
        }
        return try? decode(mutation.payload).event.cardID
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
                    failedAt: cardBefore.failedAt,
                    queueState: cardBefore.queueState
                )
            )
        )
    }

    private func drain(
        userID: Int,
        generation: Int
    ) async throws -> ReviewEventFlushResult {
        var quarantinedCount = 0
        var result = ReviewEventFlushResult()
        do {
            while true {
                try ensureActive(userID: userID, generation: generation)
                let batch = try nextBatch(userID: userID)
                guard !batch.isEmpty else { break }
                try await deliver(batch, userID: userID, generation: generation,
                                  result: &result, quarantinedCount: &quarantinedCount)
            }

            if quarantinedCount > 0 {
                throw QuarantinedReviewError(count: quarantinedCount)
            }
            return result
        } catch {
            guard !result.isEmpty else { throw error }
            throw ReviewEventFlushFailure(result: result, underlyingError: error)
        }
    }

    private func deliver(
        _ batch: [PendingMutation], userID: Int, generation: Int,
        result: inout ReviewEventFlushResult, quarantinedCount: inout Int
    ) async throws {
        let events = try batch.map { try decode($0.payload).event }
        do {
            try await send(events, removing: batch, userID: userID, generation: generation)
        } catch let APIClientError.rejected(status, _) where Self.isPermanentRejection(status) {
            for (mutation, event) in zip(batch, events) {
                switch try await retryIndividually(mutation, event, userID: userID, generation: generation) {
                case .accepted: break
                case .locked: result.progressionLockedEventIDs.insert(event.id)
                case .quarantined: quarantinedCount += 1
                }
            }
        } catch {
            try ensureActive(userID: userID, generation: generation)
            try recordRetryableFailure(batch)
            throw error
        }
    }

    private func nextBatch(userID: Int) throws -> [PendingMutation] {
        let pending = try context.fetch(FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID && $0.kind == "review" && $0.lastError == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        var ready: [PendingMutation] = []
        for mutation in pending {
            if try !hasPendingCardCreate(for: mutation.resourceID, userID: userID)
                && !hasEarlierCardAction(than: mutation, userID: userID) {
                ready.append(mutation)
            }
            if ready.count == Self.uploadBatchSize { break }
        }
        return ready
    }

    private func send(
        _ events: [ReviewBatchRequest.Event], removing mutations: [PendingMutation],
        userID: Int, generation: Int
    ) async throws {
        try ensureActive(userID: userID, generation: generation)
        try await api.request(
            "/api/card-review-events/batch", method: "POST", body: ReviewBatchRequest(events: events)
        )
        // Switching accounts leaves events on the original account for an idempotent retry.
        try ensureActive(userID: userID, generation: generation)
        mutations.forEach(context.delete)
        try context.save()
    }

    private enum DeliveryResult { case accepted, locked, quarantined }

    private static func isPermanentRejection(_ status: Int) -> Bool {
        [400, 404, 409, 410, 422].contains(status)
    }

    private func retryIndividually(
        _ mutation: PendingMutation, _ event: ReviewBatchRequest.Event, userID: Int, generation: Int
    ) async throws -> DeliveryResult {
        do {
            try await send([event], removing: [mutation], userID: userID, generation: generation)
            return .accepted
        } catch let APIClientError.rejected(status, message) where Self.isPermanentRejection(status) {
            try ensureActive(userID: userID, generation: generation)
            if Self.isProgressionLocked(status: status, message: message) {
                try localCardRepository.markProgressionLocked(matching: [mutation.resourceID, event.cardID], userID: userID)
                context.delete(mutation)
                try context.save()
                return .locked
            }
            mutation.attemptCount += 1
            mutation.lastAttemptAt = .now
            mutation.lastError = "HTTP \(status): \(message)"
            try context.save()
            return .quarantined
        } catch {
            try ensureActive(userID: userID, generation: generation)
            try recordRetryableFailure([mutation])
            throw error
        }
    }

    private func recordRetryableFailure(_ mutations: [PendingMutation]) throws {
        for mutation in mutations {
            mutation.attemptCount += 1
            mutation.lastAttemptAt = .now
            mutation.lastError = nil
        }
        try context.save()
    }

    // The API does not expose a machine-readable error code for this conflict.
    // Keep the comparison exact so unrelated 409s remain visible for recovery,
    // and cover the current backend wire message with tests until one is added.
    private static let progressionLockedMessage =
        "Card is locked by a learning progression."

    private static func isProgressionLocked(status: Int, message: String) -> Bool {
        status == 409
            && message.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(progressionLockedMessage) == .orderedSame
    }

    private static func isProgressionLockedFailure(_ message: String?) -> Bool {
        message?.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("HTTP 409: \(progressionLockedMessage)")
            == .orderedSame
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

    private func hasEarlierCardAction(
        than mutation: PendingMutation,
        userID: Int
    ) throws -> Bool {
        let decodedReviewCardID = (try? decode(mutation.payload).event.cardID.lowercased())
        let reviewIdentifiers = Set([
            mutation.resourceID.lowercased(),
            decodedReviewCardID,
        ].compactMap { $0 })
        return try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "cardAction"
                }
            )
        ).contains { action in
            let isEarlier = action.createdAt < mutation.createdAt
                || (action.createdAt == mutation.createdAt && action.id < mutation.id)
            return isEarlier && reviewIdentifiers.contains(action.resourceID.lowercased())
        }
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

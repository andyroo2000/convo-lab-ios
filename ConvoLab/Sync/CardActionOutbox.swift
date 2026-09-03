import Foundation
import SwiftData

struct PendingCardActionPayload: Codable, Equatable, Sendable {
    let request: StudyCardActionRequest
}

struct CardActionAcknowledgement {
    let response: StudyCardActionResponse
    let preservingNewerAction: Bool
}

struct QuarantinedCardActionError: LocalizedError {
    let count: Int

    var errorDescription: String? {
        "\(count) scheduling \(count == 1 ? "action was" : "actions were") rejected and held for inspection."
    }
}

final class CardActionOutbox {
    private enum DeliveryOutcome {
        case acknowledged
        case quarantined
    }

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
    func stage(cardID: String, request: StudyCardActionRequest) throws -> PendingMutation {
        guard let userID = activeUserID else { throw CancellationError() }
        let mutation = PendingMutation(
            kind: "cardAction",
            userID: userID,
            resourceID: cardID,
            payload: try StorageCodec.encoder.encode(PendingCardActionPayload(request: request))
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
            // Keep FIFO ordering stable even if the system clock moves backwards
            // or two actions receive the same storage timestamp.
            mutation.createdAt = latestCreatedAt.addingTimeInterval(0.001)
        }
        context.insert(mutation)
        return mutation
    }

    func pendingIdentifiers() throws -> Set<String> {
        guard let userID = activeUserID else { return [] }
        return Set(try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "cardAction" && $0.lastError == nil
                }
            )
        ).map { $0.resourceID.lowercased() })
    }

    func hasPendingAction(for cardID: String) throws -> Bool {
        guard let userID = activeUserID else { return false }
        let normalizedID = cardID.lowercased()
        return try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "cardAction" && $0.lastError == nil
                }
            )
        ).contains { $0.resourceID.lowercased() == normalizedID }
    }

    func pendingDeliverableCount() throws -> Int {
        guard let userID = activeUserID else { return 0 }
        return try context.fetchCount(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && $0.kind == "cardAction"
                        && $0.lastError == nil
                }
            )
        )
    }

    func flush(
        onAcknowledged: @escaping (CardActionAcknowledgement) throws -> Void
    ) async throws {
        if let flushTask {
            return try await flushTask.value
        }
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await drain(
                userID: userID,
                generation: operationGeneration,
                onAcknowledged: onAcknowledged
            )
        }
        flushTask = task
        defer {
            if generation == operationGeneration {
                flushTask = nil
            }
        }
        try await task.value
    }

    private func drain(
        userID: Int,
        generation: Int,
        onAcknowledged: (CardActionAcknowledgement) throws -> Void
    ) async throws {
        var quarantinedCount = 0
        while true {
            try ensureActive(userID: userID, generation: generation)
            let descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && $0.kind == "cardAction"
                        && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            let pending = try context.fetch(descriptor)
            guard let mutation = try pending.first(where: {
                try !hasEarlierReview(than: $0, userID: userID)
            }) else {
                if quarantinedCount > 0 {
                    throw QuarantinedCardActionError(count: quarantinedCount)
                }
                return
            }

            let outcome = try await deliver(
                mutation,
                userID: userID,
                generation: generation,
                onAcknowledged: onAcknowledged
            )
            if case .quarantined = outcome {
                quarantinedCount += 1
            }
        }
    }

    private func deliver(
        _ mutation: PendingMutation,
        userID: Int,
        generation: Int,
        onAcknowledged: (CardActionAcknowledgement) throws -> Void
    ) async throws -> DeliveryOutcome {
        do {
            let payload = try StorageCodec.decoder.decode(
                PendingCardActionPayload.self,
                from: mutation.payload
            )
            let response: StudyCardActionResponse = try await api.request(
                "/api/study/cards/\(mutation.resourceID)/actions",
                method: "POST",
                body: payload.request
            )
            try ensureActive(userID: userID, generation: generation)
            let preservingNewerAction = try hasNewerAction(
                than: mutation,
                userID: userID
            )
            try onAcknowledged(CardActionAcknowledgement(
                response: response,
                preservingNewerAction: preservingNewerAction
            ))
            context.delete(mutation)
            try context.save()
            return .acknowledged
        } catch let APIClientError.rejected(status, message)
            where [400, 404, 409, 410, 422].contains(status)
        {
            try quarantine(
                mutation,
                message: "HTTP \(status): \(message)",
                userID: userID,
                generation: generation
            )
            return .quarantined
        } catch is DecodingError {
            try quarantine(
                mutation,
                message: "Queued scheduling action data is invalid.",
                userID: userID,
                generation: generation
            )
            return .quarantined
        } catch {
            try ensureActive(userID: userID, generation: generation)
            mutation.attemptCount += 1
            mutation.lastAttemptAt = .now
            mutation.lastError = nil
            try context.save()
            throw error
        }
    }

    private func quarantine(
        _ mutation: PendingMutation,
        message: String,
        userID: Int,
        generation: Int
    ) throws {
        try ensureActive(userID: userID, generation: generation)
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        mutation.lastError = message
        try context.save()
    }

    private func hasNewerAction(
        than mutation: PendingMutation,
        userID: Int
    ) throws -> Bool {
        let normalizedID = mutation.resourceID.lowercased()
        return try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "cardAction" && $0.lastError == nil
                }
            )
        ).contains {
            $0.id != mutation.id
                && $0.resourceID.lowercased() == normalizedID
                && ($0.createdAt > mutation.createdAt
                    || ($0.createdAt == mutation.createdAt && $0.id > mutation.id))
        }
    }

    private func hasEarlierReview(
        than mutation: PendingMutation,
        userID: Int
    ) throws -> Bool {
        let actionCardID = mutation.resourceID.lowercased()
        return try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "review"
                }
            )
        ).contains { review in
            guard isOrdered(review, before: mutation) else { return false }
            let reviewCardID = (
                try? StorageCodec.decoder.decode(
                    PendingReviewPayload.self,
                    from: review.payload
                ).event.cardID.lowercased()
            ) ?? review.resourceID.lowercased()
            return review.resourceID.lowercased() == actionCardID
                || reviewCardID == actionCardID
        }
    }

    private func isOrdered(_ lhs: PendingMutation, before rhs: PendingMutation) -> Bool {
        lhs.createdAt < rhs.createdAt
            || (lhs.createdAt == rhs.createdAt && lhs.id < rhs.id)
    }

    private func ensureActive(userID: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard activeUserID == userID, self.generation == generation else {
            throw CancellationError()
        }
    }
}

enum StudyCardActionProjection {
    struct InvalidSetDueRequestError: LocalizedError {
        var errorDescription: String? {
            "Choose when this card should be due."
        }
    }

    static func prepare(
        action: StudyCardActionName,
        card: StudyCard,
        mode: StudyCardSetDueMode?,
        dueAt: Date?,
        timeZone: TimeZone,
        now: Date
    ) throws -> (request: StudyCardActionRequest, card: StudyCard) {
        let request: StudyCardActionRequest
        let projectedState: StudyCard.State

        switch action {
        case .suspend:
            request = StudyCardActionRequest(
                action: .suspend,
                mode: nil,
                dueAt: nil,
                timeZone: nil
            )
            projectedState = replacingState(card, queueState: "suspended")
        case .forget:
            request = StudyCardActionRequest(
                action: .forget,
                mode: nil,
                dueAt: nil,
                timeZone: nil
            )
            projectedState = StudyCard.State(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: freshNewScheduler(at: now),
                source: card.state.source
            )
        case .setDue:
            let resolvedDueAt = try resolvedDueAt(
                mode: mode,
                dueAt: dueAt,
                timeZone: timeZone,
                now: now
            )
            // Freeze relative choices into an absolute timestamp before they enter
            // durable storage. Replaying the same request then remains idempotent
            // even if the response was lost or the next retry happens another day.
            request = StudyCardActionRequest(
                action: .setDue,
                mode: .customDate,
                dueAt: resolvedDueAt,
                timeZone: nil
            )
            let queueState = restoredQueueState(for: card)
            projectedState = replacingState(
                card,
                dueAt: resolvedDueAt,
                queueState: queueState,
                scheduler: dueOverrideScheduler(
                    card.state.scheduler,
                    dueAt: resolvedDueAt,
                    queueState: queueState,
                    now: now
                )
            )
        case .unsuspend:
            request = StudyCardActionRequest(
                action: .unsuspend,
                mode: nil,
                dueAt: nil,
                timeZone: nil
            )
            let resolvedDueAt = card.state.dueAt ?? now
            let queueState = restoredQueueState(for: card)
            projectedState = replacingState(
                card,
                dueAt: resolvedDueAt,
                queueState: queueState,
                scheduler: dueOverrideScheduler(
                    card.state.scheduler,
                    dueAt: resolvedDueAt,
                    queueState: queueState,
                    now: now
                )
            )
        }

        return (
            request,
            StudyCard(
                id: card.id,
                syncId: card.syncId,
                noteId: card.noteId,
                revision: card.revision,
                cardType: card.cardType,
                prompt: card.prompt,
                answer: card.answer,
                serverPresentation: card.serverPresentation,
                state: projectedState,
                answerAudioSource: card.answerAudioSource,
                masteryLevel: card.masteryLevel,
                variantGroupId: card.variantGroupId,
                variantStatus: card.variantStatus,
                introductionCohortId: card.introductionCohortId,
                selectionPolicy: card.selectionPolicy,
                priorityUntil: card.priorityUntil,
                introductionAvailableAt: card.introductionAvailableAt,
                createdAt: card.createdAt,
                updatedAt: now
            )
        )
    }

    private static func resolvedDueAt(
        mode: StudyCardSetDueMode?,
        dueAt: Date?,
        timeZone: TimeZone,
        now: Date
    ) throws -> Date {
        switch mode {
        case .now:
            return now
        case .tomorrow:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  let localNine = calendar.date(
                    bySettingHour: 9,
                    minute: 0,
                    second: 0,
                    of: tomorrow
                  )
            else {
                throw InvalidSetDueRequestError()
            }
            return localNine
        case .customDate:
            guard let dueAt else { throw InvalidSetDueRequestError() }
            return dueAt
        case nil:
            throw InvalidSetDueRequestError()
        }
    }

    private static func replacingState(
        _ card: StudyCard,
        dueAt: Date? = nil,
        queueState: String,
        scheduler: JSONValue? = nil
    ) -> StudyCard.State {
        StudyCard.State(
            dueAt: dueAt ?? card.state.dueAt,
            introducedAt: card.state.introducedAt,
            failedAt: card.state.failedAt,
            queueState: queueState,
            scheduler: scheduler ?? card.state.scheduler,
            source: card.state.source
        )
    }

    private static func restoredQueueState(for card: StudyCard) -> String {
        if ["learning", "review", "relearning"].contains(card.state.queueState) {
            return card.state.queueState
        }
        guard case let .number(rawState)? = card.state.scheduler?["state"] else {
            return "review"
        }
        return switch Int(rawState) {
        case 1: "learning"
        case 3: "relearning"
        default: "review"
        }
    }

    private static func freshNewScheduler(at now: Date) -> JSONValue {
        .object([
            "due": .string(ISO8601Milliseconds.string(from: now)),
            "stability": .number(0.1),
            "difficulty": .number(5),
            "elapsed_days": .number(0),
            "scheduled_days": .number(0),
            "learning_steps": .number(0),
            "reps": .number(0),
            "lapses": .number(0),
            "state": .number(0),
            "last_review": .null,
        ])
    }

    private static func dueOverrideScheduler(
        _ scheduler: JSONValue?,
        dueAt: Date,
        queueState: String,
        now: Date
    ) -> JSONValue {
        let scheduledDays = max(
            0,
            Int((dueAt.timeIntervalSince(now) / 86_400).rounded())
        )
        let state: Double = switch queueState {
        case "learning": 1
        case "relearning": 3
        default: 2
        }
        return (scheduler ?? .object([:])).replacingObjectValues([
            "due": .string(ISO8601Milliseconds.string(from: dueAt)),
            "scheduled_days": .number(Double(scheduledDays)),
            "state": .number(state),
        ])
    }
}

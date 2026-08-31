import Foundation
import SwiftData

struct CardMutationAcknowledgement {
    let card: StudyCard
    let preservingPendingReview: Bool
    let preservingPendingEdit: Bool
    let submittedPromptAudio: JSONValue?
    let submittedAnswerAudioFields: [String: JSONValue]?
}

private struct CardUpdatePreservingAnswerAudio: Codable {
    let request: UpdateStudyCardRequest
    let submittedPromptAudio: JSONValue?
    let submittedAnswerAudioFields: [String: JSONValue]
}

private struct PendingAnswerAudioReconciliation: Codable {
    let fields: [String: JSONValue]
    let promptAudio: JSONValue?
}

struct QuarantinedCardMutationError: LocalizedError {
    let count: Int

    var errorDescription: String? {
        "\(count) card \(count == 1 ? "change was" : "changes were") rejected and held for inspection."
    }
}

final class CardMutationOutbox {
    private static let answerAudioReconciliationKind = "cardAnswerAudioReconciliation"
    private static let answerAudioFieldNames = [
        "answerAudio",
        "answerAudioVoiceId",
        "answerAudioTextOverride",
    ]

    private let api: APIClient
    private let context: ModelContext
    private let reviewOutbox: ReviewEventOutbox
    private var activeUserID: Int?
    private var flushTask: Task<Void, Error>?
    private var generation = 0

    init(
        api: APIClient,
        context: ModelContext,
        reviewOutbox: ReviewEventOutbox
    ) {
        self.api = api
        self.context = context
        self.reviewOutbox = reviewOutbox
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
    func stageCreate(
        cardID: String,
        request: CreateStudyCardRequest
    ) throws -> PendingMutation {
        try stage(
            kind: "cardCreate",
            cardID: cardID,
            payload: StorageCodec.encoder.encode(request)
        )
    }

    @discardableResult
    func stageUpdate(
        cardID: String,
        request: UpdateStudyCardRequest
    ) throws -> PendingMutation {
        let payload: Data
        let pendingAudio = try pendingAnswerAudioReconciliation(for: cardID)
        if let pendingAudio,
           pendingAudio.fields["answerAudio"] == request.answer["answerAudio"],
           request.answer["answerAudio"] != nil
        {
            let submittedAnswerAudioFields = Self.answerAudioFields(in: request.answer)
            let submittedPromptAudio = pendingAudio.promptAudio == request.prompt["cueAudio"]
                ? pendingAudio.promptAudio
                : nil
            payload = try StorageCodec.encoder.encode(CardUpdatePreservingAnswerAudio(
                request: request,
                submittedPromptAudio: submittedPromptAudio,
                submittedAnswerAudioFields: submittedAnswerAudioFields
            ))
        } else {
            if pendingAudio != nil, let userID = activeUserID {
                try clearAnswerAudioReconciliationMarker(
                    for: cardID,
                    userID: userID
                )
            }
            payload = try StorageCodec.encoder.encode(request)
        }
        return try stage(
            kind: "cardUpdate",
            cardID: cardID,
            payload: payload
        )
    }

    func trackRegeneratedAnswerAudio(
        cardID: String,
        prompt: JSONValue? = nil,
        answer: JSONValue
    ) throws {
        guard let userID = activeUserID else { throw CancellationError() }
        let fields = Self.answerAudioFields(in: answer)
        guard fields["answerAudio"] != nil else { return }
        let payload = try StorageCodec.encoder.encode(
            PendingAnswerAudioReconciliation(
                fields: fields,
                promptAudio: prompt?["cueAudio"]
            )
        )
        if let marker = try answerAudioReconciliationMarker(
            for: cardID,
            userID: userID
        ) {
            marker.payload = payload
        } else {
            context.insert(PendingMutation(
                kind: Self.answerAudioReconciliationKind,
                userID: userID,
                resourceID: cardID,
                payload: payload
            ))
        }
    }

    @discardableResult
    func stageDelete(cardID: String) throws -> PendingMutation {
        if let userID = activeUserID {
            try clearAnswerAudioReconciliationMarker(
                for: cardID,
                userID: userID
            )
        }
        return try stage(kind: "cardDelete", cardID: cardID, payload: Data())
    }

    static func updateRequest(from payload: Data) throws -> UpdateStudyCardRequest {
        if let wrapped = try? StorageCodec.decoder.decode(
            CardUpdatePreservingAnswerAudio.self,
            from: payload
        ) {
            return wrapped.request
        }
        return try StorageCodec.decoder.decode(
            UpdateStudyCardRequest.self,
            from: payload
        )
    }

    func flush(
        onDrainFinished: @escaping () -> Void = {},
        onRevisionConflict: @escaping (StudyCard) throws -> Void = { _ in },
        onAcknowledgedCard: @escaping (CardMutationAcknowledgement) throws -> Void
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
                onDrainFinished: onDrainFinished,
                onRevisionConflict: onRevisionConflict,
                onAcknowledgedCard: onAcknowledgedCard
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

    func pendingDeleteIdentifiers() throws -> Set<String> {
        guard let userID = activeUserID else { return [] }
        return Set(try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID && $0.kind == "cardDelete"
                }
            )
        ).map { $0.resourceID.lowercased() })
    }

    func pendingWriteIdentifiers() throws -> Set<String> {
        guard let userID = activeUserID else { return [] }
        return Set(try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate" || $0.kind == "cardUpdate")
                }
            )
        ).map { $0.resourceID.lowercased() })
    }

    func hasPendingDelete(for card: StudyCard) throws -> Bool {
        StudyCardIdentity.matches(card, any: try pendingDeleteIdentifiers())
    }

    func hasPendingCreate(for cardID: String) throws -> Bool {
        guard let userID = activeUserID else { return false }
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

    func hasPendingCardWrite(for cardID: String) throws -> Bool {
        guard let userID = activeUserID else { return false }
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && ($0.kind == "cardCreate" || $0.kind == "cardUpdate")
                    && $0.resourceID == cardID
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    func hasPendingMutation(for cardID: String, userID: Int) throws -> Bool {
        let normalizedID = cardID.lowercased()
        return try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate"
                            || $0.kind == "cardUpdate"
                            || $0.kind == "cardDelete"
                            || $0.kind == "cardAction"
                            || $0.kind == "review")
                }
            )
        ).contains { $0.resourceID.lowercased() == normalizedID }
    }

    private func stage(
        kind: String,
        cardID: String,
        payload: Data
    ) throws -> PendingMutation {
        guard let userID = activeUserID else { throw CancellationError() }
        let mutation = PendingMutation(
            kind: kind,
            userID: userID,
            resourceID: cardID,
            payload: payload
        )
        context.insert(mutation)
        return mutation
    }

    private func drain(
        userID: Int,
        generation: Int,
        onDrainFinished: () -> Void,
        onRevisionConflict: (StudyCard) throws -> Void,
        onAcknowledgedCard: (CardMutationAcknowledgement) throws -> Void
    ) async throws {
        defer { onDrainFinished() }
        var quarantinedCount = 0
        while true {
            try ensureActive(userID: userID, generation: generation)
            var descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate"
                            || $0.kind == "cardUpdate"
                            || $0.kind == "cardDelete")
                        && $0.lastError == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            descriptor.fetchLimit = 1
            guard let mutation = try context.fetch(descriptor).first else {
                if quarantinedCount > 0 {
                    throw QuarantinedCardMutationError(count: quarantinedCount)
                }
                return
            }

            do {
                let clientResourceID = mutation.resourceID
                let serverCard: StudyCard?
                var submittedPromptAudio: JSONValue?
                var submittedAnswerAudioFields: [String: JSONValue]?
                switch mutation.kind {
                case "cardCreate":
                    let request = try StorageCodec.decoder.decode(
                        CreateStudyCardRequest.self,
                        from: mutation.payload
                    )
                    serverCard = try await api.request(
                        "/api/study/cards",
                        method: "POST",
                        body: request
                    )
                case "cardUpdate":
                    let request: UpdateStudyCardRequest
                    if let wrapped = try? StorageCodec.decoder.decode(
                        CardUpdatePreservingAnswerAudio.self,
                        from: mutation.payload
                    ) {
                        request = wrapped.request
                        submittedPromptAudio = wrapped.submittedPromptAudio
                        submittedAnswerAudioFields = wrapped.submittedAnswerAudioFields
                    } else {
                        request = try StorageCodec.decoder.decode(
                            UpdateStudyCardRequest.self,
                            from: mutation.payload
                        )
                    }
                    serverCard = try await api.request(
                        "/api/study/cards/\(mutation.resourceID)",
                        method: "PATCH",
                        body: request,
                        decodingStudyCardRevisionConflict: true
                    )
                case "cardDelete":
                    try await api.request(
                        "/api/study/cards/\(mutation.resourceID)",
                        method: "DELETE"
                    )
                    serverCard = nil
                default:
                    return
                }

                // If the account switches after server acceptance, retain the
                // stable request for an idempotent retry under its original user.
                try ensureActive(userID: userID, generation: generation)
                if mutation.kind == "cardCreate", let serverCard {
                    try reconcileCreatedCardID(
                        from: clientResourceID,
                        to: serverCard.id,
                        userID: userID
                    )
                }
                if let serverCard, try !hasPendingDelete(for: serverCard) {
                    let preservingPendingEdit = try hasPendingUpdate(
                        for: serverCard.id,
                        excluding: mutation.id,
                        userID: userID
                    )
                    try onAcknowledgedCard(CardMutationAcknowledgement(
                        card: serverCard,
                        preservingPendingReview: reviewOutbox.hasPendingReview(
                            for: serverCard.id
                        ),
                        preservingPendingEdit: preservingPendingEdit,
                        submittedPromptAudio: submittedPromptAudio,
                        submittedAnswerAudioFields: submittedAnswerAudioFields
                    ))
                    if let submittedAnswerAudioFields,
                       submittedAnswerAudioFields.allSatisfy({ key, value in
                           serverCard.answer[key] == value
                       }),
                       submittedPromptAudio == nil
                           || serverCard.prompt["cueAudio"] == submittedPromptAudio
                    {
                        try clearAnswerAudioReconciliationMarker(
                            for: clientResourceID,
                            userID: userID
                        )
                    }
                }
                context.delete(mutation)
                try context.save()
            } catch let APIClientError.rejected(status, _)
                where mutation.kind == "cardDelete" && status == 404
            {
                try ensureActive(userID: userID, generation: generation)
                context.delete(mutation)
                try context.save()
            } catch let conflict as StudyCardRevisionConflictError {
                try ensureActive(userID: userID, generation: generation)
                quarantinedCount += try quarantineRevisionConflicts(
                    for: mutation,
                    userID: userID,
                    message: conflict.message
                )
                try onRevisionConflict(conflict.currentCard)
                try context.save()
            } catch let APIClientError.rejected(status, message)
                where [400, 404, 409, 410, 422].contains(status)
            {
                try ensureActive(userID: userID, generation: generation)
                mutation.attemptCount += 1
                mutation.lastAttemptAt = .now
                mutation.lastError = "HTTP \(status): \(message)"
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
    }

    private static func answerAudioFields(in answer: JSONValue) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: answerAudioFieldNames.compactMap { key in
            answer[key].map { (key, $0) }
        })
    }

    private func pendingAnswerAudioReconciliation(
        for cardID: String
    ) throws -> PendingAnswerAudioReconciliation? {
        guard let userID = activeUserID else { return nil }
        guard let marker = try answerAudioReconciliationMarker(
            for: cardID,
            userID: userID
        ) else {
            return nil
        }
        return try StorageCodec.decoder.decode(
            PendingAnswerAudioReconciliation.self,
            from: marker.payload
        )
    }

    private func answerAudioReconciliationMarker(
        for cardID: String,
        userID: Int
    ) throws -> PendingMutation? {
        let kind = Self.answerAudioReconciliationKind
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == kind
                    && $0.resourceID == cardID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func clearAnswerAudioReconciliationMarker(
        for cardID: String,
        userID: Int
    ) throws {
        if let marker = try answerAudioReconciliationMarker(
            for: cardID,
            userID: userID
        ) {
            context.delete(marker)
        }
    }

    private func reconcileCreatedCardID(
        from clientID: String,
        to serverID: String,
        userID: Int
    ) throws {
        guard clientID != serverID else { return }

        var clientDescriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.id == clientID }
        )
        clientDescriptor.fetchLimit = 1
        var serverDescriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.id == serverID }
        )
        serverDescriptor.fetchLimit = 1
        let clientRecord = try context.fetch(clientDescriptor).first
        let serverRecord = try context.fetch(serverDescriptor).first
        let mutationDescriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && ($0.resourceID == clientID || $0.resourceID == serverID)
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
                    clientRecord.replaceID(with: serverID)
                }
                try context.save()
            } else {
                clientRecord.replaceID(with: serverID)
            }
        }

        for pending in aliasMutations
        where pending.resourceID == clientID && pending.kind != "cardCreate" {
            if pending.kind == "review" {
                try reviewOutbox.retarget(pending, cardID: serverID)
            } else {
                pending.resourceID = serverID
            }
        }
    }

    private func localActivityDate(for record: LocalCardRecord) -> Date {
        let cardUpdatedAt = (try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        ))?.updatedAt ?? .distantPast
        return max(record.locallyUpdatedAt ?? .distantPast, cardUpdatedAt)
    }

    private func hasPendingUpdate(
        for cardID: String,
        excluding mutationID: String,
        userID: Int
    ) throws -> Bool {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == "cardUpdate"
                    && $0.resourceID == cardID
                    && $0.id != mutationID
                    && $0.lastError == nil
            }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func quarantineRevisionConflicts(
        for mutation: PendingMutation,
        userID: Int,
        message: String
    ) throws -> Int {
        let normalizedResourceID = mutation.resourceID.lowercased()
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == "cardUpdate"
                    && $0.lastError == nil
            }
        )
        let conflicts = try context.fetch(descriptor).filter {
            $0.resourceID.lowercased() == normalizedResourceID
        }
        let attemptedAt = Date.now
        for conflict in conflicts {
            conflict.attemptCount += 1
            conflict.lastAttemptAt = attemptedAt
            conflict.lastError = "HTTP 409 [\(StudyCardRevisionConflictError.code)]: \(message)"
        }
        try context.save()
        return conflicts.count
    }

    private func ensureActive(userID: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard activeUserID == userID, self.generation == generation else {
            throw CancellationError()
        }
    }
}

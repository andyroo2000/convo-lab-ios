import Foundation
import SwiftData

extension StudyStore {
    struct MissingLocalCardError: LocalizedError {
        var errorDescription: String? {
            "This card changed during sync. Close the editor and try again."
        }
    }

    struct MissingAcknowledgedCardError: LocalizedError {
        var errorDescription: String? {
            "Card sync stopped because its local record is missing. Refresh and try again."
        }
    }

    private struct CardActionInProgressError: LocalizedError {
        var errorDescription: String? {
            "This card’s review schedule is already being updated."
        }
    }

    func createCard(
        expression: String,
        reading: String,
        meaning: String
    ) async throws {
        var draft = StudyCardDraft(
            defaultAnswerAudioVoiceID: capabilities.cardAuthoring.randomDefaultVoiceId()
        )
        applyTextInput((expression, reading, meaning), to: &draft)
        try await createCard(draft)
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

        await flushCardEdits(userID: userID, activationGeneration: activationGeneration)
        return optimistic
    }

    func updateCard(
        _ card: StudyCard,
        prompt: String,
        reading: String,
        answer: String
    ) async throws {
        var draft = StudyCardDraft(
            card: card,
            defaultAnswerAudioVoiceID: capabilities.cardAuthoring.defaultAnswerAudioVoiceId
        )
        applyTextInput((prompt, reading, answer), to: &draft)
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
        try cardOutbox.stageUpdate(
            cardID: currentCard.id,
            request: projection.request
        )
        cards = cards.map { $0.id == currentCard.id ? updated : $0 }
        libraryCards = libraryCards.map { $0.id == currentCard.id ? updated : $0 }
        allCards = allCards.map { $0.id == currentCard.id ? updated : $0 }
        reconcileLearningItems(upserting: updated)
        reconcileCachedDefaultLearningItems(upserting: updated)
        reconcilePendingCardMutationsIntoNewCardQueue()
        try context.save()
        persistCardCatalogSnapshot()
        await flushCardEdits(userID: userID, activationGeneration: activationGeneration)
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
        removeFromCachedDefaultLearningItems(currentCard)
        reconcilePendingCardMutationsIntoNewCardQueue()
        try context.save()
        persistCardCatalogSnapshot()
        await flushCardEdits(userID: userID, activationGeneration: activationGeneration)
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
        let projectedCard = try stageCardAction(
            StudyCardActionExecution.Input(
                action: action,
                card: card,
                mode: mode,
                dueAt: dueAt,
                timeZone: timeZone
            )
        )
        await flushCardActionDependencies(
            userID: userID,
            activationGeneration: activationGeneration
        )
        return try currentLocalCard(for: projectedCard)
    }

    private func stageCardAction(
        _ input: StudyCardActionExecution.Input
    ) throws -> StudyCard {
        let currentCard = try currentLocalCard(for: input.card)
        let prepared = try StudyCardActionProjection.prepare(
            action: input.action,
            card: currentCard,
            mode: input.mode,
            dueAt: input.dueAt,
            timeZone: input.timeZone,
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
        return prepared.card
    }

    private func flushCardActionDependencies(
        userID: Int,
        activationGeneration: Int
    ) async {
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
    }
    private func flushCardEdits(userID: Int, activationGeneration: Int) async {
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
    private func applyTextInput(
        _ input: (expression: String, reading: String, meaning: String),
        to draft: inout StudyCardDraft
    ) {
        draft.cueText = input.expression
        draft.cueReading = input.reading
        draft.answerExpression = input.expression
        draft.answerMeaning = input.meaning
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


}

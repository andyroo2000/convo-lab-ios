import Foundation
import SwiftData

extension StudyStore {
    private struct ReviewRestorationMembership {
        let presentationIsCurrent: Bool
        let belongsToActiveReviewSession: Bool
    }

    func restorePendingReviewState() {
        guard let state = try? reviewOutbox.pendingState() else { return }
        apply(state)
    }

    func apply(_ state: PendingReviewState) {
        newlyFailedCardIDs = state.newlyFailedCardIDs
        retainedFailedCardIDs = state.retainedFailedCardIDs
        resolvedFailedCardIDs = state.resolvedFailedCardIDs
    }

    @discardableResult
    func restoreReviewedCard(
        _ card: StudyCard,
        preservingLocalPresentation: Bool = false,
        presentationRevision: Int,
        undoingPresentedLesson: Bool
    ) throws -> StudyCard {
        guard try !cardOutbox.hasPendingDelete(for: card) else {
            throw DeletedCardUndoError()
        }
        let record = try reviewRestorationRecord(for: card)
        let restoredCard = restoredCard(
            card,
            matching: record,
            preservingLocalPresentation: preservingLocalPresentation
        )
        let membership = ReviewRestorationMembership(
            presentationIsCurrent: presentationRevision == studySurfaceRevision,
            belongsToActiveReviewSession: !undoingPresentedLesson
        )
        publishRestoredReviewPresentation(
            restoredCard,
            presentationIsCurrent: membership.presentationIsCurrent
        )

        try updateRestoredReviewRecord(
            record,
            with: restoredCard,
            membership: membership
        )
        try persistRestoredReview(membership: membership)
        scheduleNextOfflineActivation()
        return restoredCard
    }

    private func publishRestoredReviewPresentation(
        _ card: StudyCard,
        presentationIsCurrent: Bool
    ) {
        let normalizedID = card.id.lowercased()
        if presentationIsCurrent {
            masteryAnimation = nil
            sessionCompletedCardIDs = Set(
                sessionCompletedCardIDs.filter { $0.lowercased() != normalizedID }
            )
            cards.removeAll { $0.id.lowercased() == normalizedID }
            cards.insert(card, at: 0)
        }
        if let index = libraryCards.firstIndex(
            where: { $0.id.lowercased() == normalizedID }
        ) {
            libraryCards[index] = card
        } else {
            libraryCards.append(card)
        }
        upsertAllCardsPresentation(card)
    }

    private func reviewRestorationRecord(
        for card: StudyCard
    ) throws -> LocalCardRecord? {
        guard let userID = activeUserID else { return nil }
        return try localCardRepository.record(matching: card, userID: userID)
    }

    private func updateRestoredReviewRecord(
        _ record: LocalCardRecord?,
        with card: StudyCard,
        membership: ReviewRestorationMembership
    ) throws {
        let payload = try StorageCodec.encoder.encode(card)
        if let record {
            updateRestoredReviewRecord(
                record,
                with: card,
                payload: payload,
                membership: membership
            )
            return
        }
        guard let userID = activeUserID else { throw CancellationError() }
        let newRecord = LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: 0,
            payload: payload
        )
        newRecord.isInActiveSession = membership.presentationIsCurrent
            && membership.belongsToActiveReviewSession
        context.insert(newRecord)
    }

    private func updateRestoredReviewRecord(
        _ record: LocalCardRecord,
        with card: StudyCard,
        payload: Data,
        membership: ReviewRestorationMembership
    ) {
        let wasLocallyUpdated = record.locallyUpdatedAt != nil
        record.replacePayload(encoded: payload)
        // A newer surface owns durable membership. The completed undo is still
        // authoritative card data, but it must not overwrite membership chosen
        // by a refresh, checkpoint rebuild, or lesson transition.
        if membership.presentationIsCurrent {
            record.isInActiveSession = membership.belongsToActiveReviewSession
        }
        if !wasLocallyUpdated {
            record.serverUpdatedAt = card.updatedAt
        }
    }

    private func persistRestoredReview(
        membership: ReviewRestorationMembership
    ) throws {
        guard let userID = activeUserID else { throw CancellationError() }
        if membership.presentationIsCurrent && membership.belongsToActiveReviewSession {
            try localCardRepository.replaceActiveSession(with: cards, userID: userID)
        } else {
            try context.save()
        }
    }

    private func restoredCard(
        _ card: StudyCard,
        matching record: LocalCardRecord?,
        preservingLocalPresentation: Bool
    ) -> StudyCard {
        guard let record else { return card }
        let localCard = try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        let card = localCard.map {
            card.resolvingProgressionMetadata(fallingBackTo: $0)
        } ?? card
        let preserveLocalPresentation = preservingLocalPresentation
            || record.locallyUpdatedAt != nil
        guard record.id != card.id || preserveLocalPresentation else {
            return card
        }
        let restoredServerPresentation: StudyCardPresentationV1?
        if preserveLocalPresentation, let localCard {
            restoredServerPresentation = localCard.serverPresentation
        } else {
            restoredServerPresentation = card.serverPresentation
        }

        return StudyCard(
            id: record.id,
            syncId: card.syncId ?? localCard?.syncId,
            noteId: card.noteId,
            revision: preserveLocalPresentation
                ? localCard?.revision ?? card.revision
                : card.revision,
            cardType: preserveLocalPresentation
                ? localCard?.cardType ?? card.cardType
                : card.cardType,
            prompt: preserveLocalPresentation
                ? localCard?.prompt ?? card.prompt
                : card.prompt,
            answer: preserveLocalPresentation
                ? localCard?.answer ?? card.answer
                : card.answer,
            serverPresentation: restoredServerPresentation,
            state: card.state,
            answerAudioSource: preserveLocalPresentation
                ? localCard?.answerAudioSource ?? card.answerAudioSource
                : card.answerAudioSource,
            // Scheduling state and mastery come from the undo result; neither is editor-owned.
            masteryLevel: card.masteryLevel,
            variantGroupId: card.variantGroupId,
            variantStatus: card.variantStatus,
            introductionCohortId: card.introductionCohortId,
            selectionPolicy: card.selectionPolicy,
            priorityUntil: card.priorityUntil,
            introductionAvailableAt: card.introductionAvailableAt,
            createdAt: preserveLocalPresentation
                ? localCard?.createdAt ?? card.createdAt
                : card.createdAt,
            updatedAt: preserveLocalPresentation
                ? localCard?.updatedAt ?? card.updatedAt
                : card.updatedAt
        )
    }
}

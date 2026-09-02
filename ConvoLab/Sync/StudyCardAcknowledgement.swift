import Foundation

enum StudyCardAcknowledgement {
    struct Input {
        let serverCard: StudyCard
        let localCard: StudyCard
        let persistedID: String
        let preservingPendingReview: Bool
        let preservingPendingEdit: Bool
        let submittedPromptAudio: JSONValue?
        let submittedAnswerAudioFields: [String: JSONValue]?
    }

    private struct Content {
        let prompt: JSONValue
        let answer: JSONValue
        let answerAudioResponseWasStale: Bool
    }

    static func reconcile(_ input: Input) -> StudyCard {
        let serverCard = input.serverCard.resolvingProgressionMetadata(
            fallingBackTo: input.localCard
        )
        let content = reconciledContent(input, serverCard: serverCard)
        return StudyCard(
            id: input.persistedID,
            // Keep the persisted local key while carrying the server-resolved identity as its alias.
            syncId: reconciledSyncID(input, serverCard: serverCard),
            noteId: serverCard.noteId,
            revision: reconciledRevision(input, serverCard: serverCard),
            cardType: serverCard.cardType,
            prompt: content.prompt,
            answer: content.answer,
            serverPresentation: reconciledServerPresentation(
                content,
                serverCard: serverCard
            ),
            state: reconciledState(input, serverCard: serverCard),
            answerAudioSource: reconciledAnswerAudioSource(
                input,
                content: content,
                serverCard: serverCard
            ),
            masteryLevel: reconciledMasteryLevel(input, serverCard: serverCard),
            variantGroupId: serverCard.variantGroupId,
            variantStatus: serverCard.variantStatus,
            introductionCohortId: serverCard.introductionCohortId,
            selectionPolicy: serverCard.selectionPolicy,
            priorityUntil: serverCard.priorityUntil,
            introductionAvailableAt: serverCard.introductionAvailableAt,
            createdAt: serverCard.createdAt,
            updatedAt: reconciledUpdatedAt(input, serverCard: serverCard)
        )
    }

    private static func reconciledContent(
        _ input: Input,
        serverCard: StudyCard
    ) -> Content {
        let submittedPromptFields = input.submittedPromptAudio.map {
            ["cueAudio": $0]
        }
        return Content(
            prompt: reconciledContentValue(
                preservingPendingEdit: input.preservingPendingEdit,
                localValue: input.localCard.prompt,
                serverValue: serverCard.prompt,
                submittedFields: submittedPromptFields
            ),
            answer: reconciledContentValue(
                preservingPendingEdit: input.preservingPendingEdit,
                localValue: input.localCard.answer,
                serverValue: serverCard.answer,
                submittedFields: input.submittedAnswerAudioFields
            ),
            answerAudioResponseWasStale: answerAudioResponseWasStale(
                input,
                serverCard: serverCard
            )
        )
    }

    private static func reconciledContentValue(
        preservingPendingEdit: Bool,
        localValue: JSONValue,
        serverValue: JSONValue,
        submittedFields: [String: JSONValue]?
    ) -> JSONValue {
        if preservingPendingEdit {
            return localValue
        }
        guard let submittedFields else {
            return serverValue
        }
        return serverValue.replacingObjectValues(submittedFields)
    }

    // Compatibility PATCH responses can contain the pre-regeneration audio
    // projection. Compare the exact fields written atomically by regeneration
    // and submitted by the accepted update request.
    private static func answerAudioResponseWasStale(
        _ input: Input,
        serverCard: StudyCard
    ) -> Bool {
        guard let submittedAnswerAudioFields = input.submittedAnswerAudioFields else {
            return false
        }
        return submittedAnswerAudioFields.contains { key, value in
            serverCard.answer[key] != value
        }
    }

    private static func reconciledSyncID(
        _ input: Input,
        serverCard: StudyCard
    ) -> String? {
        guard input.persistedID == serverCard.id else {
            return serverCard.reviewCardID
        }
        return serverCard.syncId ?? input.localCard.syncId
    }

    private static func reconciledRevision(
        _ input: Input,
        serverCard: StudyCard
    ) -> Int? {
        input.preservingPendingEdit ? input.localCard.revision : serverCard.revision
    }

    private static func reconciledServerPresentation(
        _ content: Content,
        serverCard: StudyCard
    ) -> StudyCardPresentationV1? {
        guard content.prompt == serverCard.prompt, content.answer == serverCard.answer else {
            return nil
        }
        return serverCard.serverPresentation
    }

    private static func reconciledState(
        _ input: Input,
        serverCard: StudyCard
    ) -> StudyCard.State {
        input.preservingPendingReview ? input.localCard.state : serverCard.state
    }

    private static func reconciledAnswerAudioSource(
        _ input: Input,
        content: Content,
        serverCard: StudyCard
    ) -> String? {
        guard !input.preservingPendingEdit, !content.answerAudioResponseWasStale else {
            return input.localCard.answerAudioSource
        }
        return serverCard.answerAudioSource
    }

    private static func reconciledMasteryLevel(
        _ input: Input,
        serverCard: StudyCard
    ) -> String? {
        // Current PATCH responses return computed, non-null mastery; legacy lean
        // responses may omit it. Editor input cannot clear mastery. If that contract
        // gains explicit clears, decoding must distinguish null from omission.
        guard !input.preservingPendingReview else {
            return input.localCard.masteryLevel
        }
        return serverCard.masteryLevel ?? input.localCard.masteryLevel
    }

    private static func reconciledUpdatedAt(
        _ input: Input,
        serverCard: StudyCard
    ) -> Date {
        guard !input.preservingPendingReview, !input.preservingPendingEdit else {
            return input.localCard.updatedAt
        }
        return serverCard.updatedAt
    }
}

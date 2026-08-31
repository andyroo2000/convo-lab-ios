import Foundation

enum StudyCardEditorProjection {
    struct Creation {
        let card: StudyCard
        let request: CreateStudyCardRequest
    }

    struct Update {
        let card: StudyCard
        let request: UpdateStudyCardRequest
    }

    static func creating(
        _ draft: StudyCardDraft,
        id: String,
        at date: Date
    ) -> Creation {
        let prompt = draft.prompt()
        let answer = draft.answer()
        return Creation(
            card: StudyCard(
                id: id,
                syncId: id,
                noteId: nil,
                revision: 0,
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
                createdAt: date,
                updatedAt: date
            ),
            request: CreateStudyCardRequest(
                id: id,
                cardType: draft.cardType.rawValue,
                prompt: prompt,
                answer: answer
            )
        )
    }

    static func updating(
        _ card: StudyCard,
        with draft: StudyCardDraft,
        at date: Date
    ) -> Update {
        let prompt = draft.prompt(merging: card.prompt)
        let answer = draft.answer(merging: card.answer)
        let projectedRevision = if prompt == card.prompt && answer == card.answer {
            card.revision
        } else {
            card.revision.map { $0 == Int.max ? Int.max : $0 + 1 }
        }
        return Update(
            card: StudyCard(
                id: card.id,
                syncId: card.syncId,
                noteId: card.noteId,
                revision: projectedRevision,
                cardType: card.cardType,
                prompt: prompt,
                answer: answer,
                state: card.state,
                answerAudioSource: card.answerAudioSource,
                masteryLevel: card.masteryLevel,
                variantGroupId: card.variantGroupId,
                variantStatus: card.variantStatus,
                introductionCohortId: card.introductionCohortId,
                selectionPolicy: card.selectionPolicy,
                priorityUntil: card.priorityUntil,
                introductionAvailableAt: card.introductionAvailableAt,
                createdAt: card.createdAt,
                updatedAt: date
            ),
            request: UpdateStudyCardRequest(
                prompt: prompt,
                answer: answer,
                expectedRevision: card.revision
            )
        )
    }

    static func reconcilingMedia(
        latest: StudyCard,
        serverCard: StudyCard,
        prompt: JSONValue,
        answer: JSONValue,
        answerAudioSource: String?,
        updatedAt: Date
    ) -> StudyCard {
        let serverCard = serverCard.resolvingProgressionMetadata(
            fallingBackTo: latest
        )
        return StudyCard(
            id: latest.id,
            syncId: serverCard.syncId ?? latest.syncId,
            noteId: serverCard.noteId ?? latest.noteId,
            revision: serverCard.revision,
            cardType: latest.cardType,
            prompt: prompt,
            answer: answer,
            state: latest.state,
            answerAudioSource: answerAudioSource,
            masteryLevel: latest.masteryLevel,
            variantGroupId: serverCard.variantGroupId,
            variantStatus: serverCard.variantStatus,
            introductionCohortId: serverCard.introductionCohortId
                ?? latest.introductionCohortId,
            selectionPolicy: serverCard.selectionPolicy ?? latest.selectionPolicy,
            priorityUntil: serverCard.priorityUntil ?? latest.priorityUntil,
            introductionAvailableAt: serverCard.introductionAvailableAt
                ?? latest.introductionAvailableAt,
            createdAt: latest.createdAt,
            updatedAt: updatedAt
        )
    }
}

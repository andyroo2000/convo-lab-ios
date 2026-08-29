import XCTest
@testable import ConvoLab

final class StudyCardEditorProjectionTests: XCTestCase {
    @MainActor
    func testCreateProjectionBuildsMatchingOptimisticCardAndRequest() {
        var draft = StudyCardDraft()
        draft.cardType = .production
        draft.cueText = "to learn"
        draft.answerExpression = "学ぶ"
        draft.answerMeaning = "to learn"
        let date = Date(timeIntervalSince1970: 100)

        let projection = StudyCardEditorProjection.creating(
            draft,
            id: "draft-id",
            at: date
        )

        XCTAssertEqual(projection.card.id, "draft-id")
        XCTAssertEqual(projection.card.syncId, "draft-id")
        XCTAssertEqual(projection.card.state.queueState, "new")
        XCTAssertEqual(projection.card.createdAt, date)
        XCTAssertEqual(projection.request.id, projection.card.id)
        XCTAssertEqual(projection.request.cardType, projection.card.cardType)
        XCTAssertEqual(projection.request.prompt, projection.card.prompt)
        XCTAssertEqual(projection.request.answer, projection.card.answer)
    }

    @MainActor
    func testUpdateAndMediaProjectionsPreserveUntouchedCardMetadata() {
        let card = makeCard(
            masteryLevel: "guru",
            variantGroupID: "family-1",
            variantStatus: "locked"
        )
        var draft = StudyCardDraft(card: card)
        draft.cueText = "updated"
        let update = StudyCardEditorProjection.updating(
            card,
            with: draft,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(update.card.masteryLevel, "guru")
        XCTAssertEqual(update.card.variantGroupId, "family-1")
        XCTAssertEqual(update.card.variantStatus, "locked")
        XCTAssertEqual(update.card.state, card.state)
        XCTAssertEqual(update.card.createdAt, card.createdAt)
        XCTAssertEqual(update.request.prompt, update.card.prompt)
        XCTAssertEqual(update.request.answer, update.card.answer)

        let serverCard = makeCard(
            id: "server-id",
            syncId: "canonical-sync-id",
            masteryLevel: nil
        )
        let reconciled = StudyCardEditorProjection.reconcilingMedia(
            latest: update.card,
            serverCard: serverCard,
            prompt: update.card.prompt,
            answer: update.card.answer,
            answerAudioSource: "generated",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(reconciled.id, update.card.id)
        XCTAssertEqual(reconciled.syncId, "canonical-sync-id")
        XCTAssertEqual(reconciled.masteryLevel, "guru")
        XCTAssertNil(reconciled.variantGroupId)
        XCTAssertNil(reconciled.variantStatus)
        XCTAssertEqual(reconciled.state, update.card.state)
        XCTAssertEqual(reconciled.createdAt, update.card.createdAt)
    }

    @MainActor
    private func makeCard(
        id: String = "local-id",
        syncId: String? = "local-sync-id",
        masteryLevel: String?,
        variantGroupID: String? = nil,
        variantStatus: String? = nil
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
            noteId: "note-id",
            cardType: "recognition",
            prompt: .object(["cueText": .string("original")]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: Date(timeIntervalSince1970: 500),
                introducedAt: Date(timeIntervalSince1970: 50),
                failedAt: nil,
                queueState: "review",
                scheduler: .object(["stability": .number(8)]),
                source: .object([:])
            ),
            answerAudioSource: "generated",
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupID,
            variantStatus: variantStatus,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

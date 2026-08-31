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
    func testUpdateAndMediaProjectionsPreserveUntouchedCardMetadata() throws {
        let card = makeCard(
            revision: 7,
            masteryLevel: "guru",
            variantGroupID: "family-1",
            variantStatus: "locked",
            introductionCohortID: "cohort-1",
            selectionPolicy: "priority",
            priorityUntil: Date(timeIntervalSince1970: 600),
            introductionAvailableAt: Date(timeIntervalSince1970: 700)
        )
        var draft = StudyCardDraft(card: card)
        draft.cueText = "updated"
        let update = StudyCardEditorProjection.updating(
            card,
            with: draft,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(update.card.masteryLevel, "guru")
        XCTAssertEqual(update.request.expectedRevision, 7)
        XCTAssertEqual(update.card.revision, 8)
        XCTAssertEqual(update.card.variantGroupId, "family-1")
        XCTAssertEqual(update.card.variantStatus, "locked")
        XCTAssertEqual(update.card.introductionCohortId, "cohort-1")
        XCTAssertEqual(update.card.selectionPolicy, "priority")
        XCTAssertEqual(update.card.priorityUntil, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(
            update.card.introductionAvailableAt,
            Date(timeIntervalSince1970: 700)
        )
        XCTAssertEqual(update.card.state, card.state)
        XCTAssertEqual(update.card.createdAt, card.createdAt)
        XCTAssertEqual(update.request.prompt, update.card.prompt)
        XCTAssertEqual(update.request.answer, update.card.answer)

        let serverCard = makeCard(
            id: "server-id",
            syncId: "canonical-sync-id",
            revision: 12,
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
        XCTAssertEqual(reconciled.revision, 12)
        XCTAssertEqual(reconciled.masteryLevel, "guru")
        XCTAssertNil(reconciled.variantGroupId)
        XCTAssertNil(reconciled.variantStatus)
        XCTAssertEqual(reconciled.introductionCohortId, "cohort-1")
        XCTAssertEqual(reconciled.selectionPolicy, "priority")
        XCTAssertEqual(reconciled.priorityUntil, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(
            reconciled.introductionAvailableAt,
            Date(timeIntervalSince1970: 700)
        )
        XCTAssertEqual(reconciled.state, update.card.state)
        XCTAssertEqual(reconciled.createdAt, update.card.createdAt)

        let leanServerCard = try omittingProgressionFields(from: serverCard)
        let leanReconciled = StudyCardEditorProjection.reconcilingMedia(
            latest: update.card,
            serverCard: leanServerCard,
            prompt: update.card.prompt,
            answer: update.card.answer,
            answerAudioSource: "generated",
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(leanReconciled.variantGroupId, "family-1")
        XCTAssertEqual(leanReconciled.variantStatus, "locked")
    }

    @MainActor
    func testNoOpUpdateKeepsRevisionWhileStillSendingExpectation() {
        let initialCard = makeCard(revision: 6, masteryLevel: nil)
        let normalized = StudyCardEditorProjection.updating(
            initialCard,
            with: StudyCardDraft(card: initialCard),
            at: Date(timeIntervalSince1970: 100)
        ).card
        let projection = StudyCardEditorProjection.updating(
            normalized,
            with: StudyCardDraft(card: normalized),
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(projection.request.expectedRevision, 7)
        XCTAssertEqual(projection.card.revision, 7)
    }

    @MainActor
    private func omittingProgressionFields(from card: StudyCard) throws -> StudyCard {
        let encoded = try StorageCodec.encoder.encode(card)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "variantGroupId")
        object.removeValue(forKey: "variantStatus")
        return try StorageCodec.decoder.decode(
            StudyCard.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @MainActor
    private func makeCard(
        id: String = "local-id",
        syncId: String? = "local-sync-id",
        revision: Int = 0,
        masteryLevel: String?,
        variantGroupID: String? = nil,
        variantStatus: String? = nil,
        introductionCohortID: String? = nil,
        selectionPolicy: String? = nil,
        priorityUntil: Date? = nil,
        introductionAvailableAt: Date? = nil
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
            noteId: "note-id",
            revision: revision,
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
            introductionCohortId: introductionCohortID,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

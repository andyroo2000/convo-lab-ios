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
        XCTAssertEqual(projection.card.revision, 0)
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

        XCTAssertEqual(update.request.expectedRevision, 7)
        XCTAssertEqual(update.request.prompt, update.card.prompt)
        XCTAssertEqual(update.request.answer, update.card.answer)
        assertUpdatedCard(update.card, preservesMetadataFrom: card)

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
        XCTAssertEqual(reconciled.syncId, "canonical-sync-id")
        XCTAssertEqual(reconciled.revision, 12)
        XCTAssertEqual(reconciled.masteryLevel, "guru")
        XCTAssertNil(reconciled.variantGroupId)
        XCTAssertNil(reconciled.variantStatus)
        assertReconciledCard(reconciled, preservesMetadataFrom: update.card)

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
    func testMediaReconciliationDropsPresentationAfterRacingCardTypeChange() throws {
        let latest = makeCard(revision: 4, masteryLevel: nil)
        let serverCard = try withPresentation(
            makeCard(revision: 5, masteryLevel: nil),
            cardType: "production"
        )

        let reconciled = StudyCardEditorProjection.reconcilingMedia(
            latest: latest,
            serverCard: serverCard,
            prompt: serverCard.prompt,
            answer: serverCard.answer,
            answerAudioSource: "generated",
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(reconciled.cardType, "recognition")
        XCTAssertNil(reconciled.serverPresentation)
    }

    @MainActor
    func testLegacyCachedCardUpdateOmitsUnknownRevision() {
        let card = makeCard(revision: nil, masteryLevel: nil)
        var draft = StudyCardDraft(card: card)
        draft.cueText = "updated"

        let projection = StudyCardEditorProjection.updating(
            card,
            with: draft,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertNil(projection.request.expectedRevision)
        XCTAssertNil(projection.card.revision)
    }

    @MainActor
    private func omittingProgressionFields(from card: StudyCard) throws -> StudyCard {
        try modifyingEncodedCard(card) { object in
            object.removeValue(forKey: "variantGroupId")
            object.removeValue(forKey: "variantStatus")
        }
    }

    @MainActor
    private func withPresentation(
        _ card: StudyCard,
        cardType: String? = nil
    ) throws -> StudyCard {
        try modifyingEncodedCard(card) { object in
            object["cardType"] = cardType ?? card.cardType
            object["presentation"] = Self.presentationFixture
        }
    }

    @MainActor
    private func modifyingEncodedCard(
        _ card: StudyCard,
        modification: (inout [String: Any]) -> Void
    ) throws -> StudyCard {
        let encoded = try StorageCodec.encoder.encode(card)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        modification(&object)
        return try StorageCodec.decoder.decode(
            StudyCard.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @MainActor
    private func assertUpdatedCard(
        _ card: StudyCard,
        preservesMetadataFrom original: StudyCard
    ) {
        XCTAssertEqual(card.masteryLevel, original.masteryLevel)
        XCTAssertEqual(card.revision, 8)
        XCTAssertEqual(card.variantGroupId, original.variantGroupId)
        XCTAssertEqual(card.variantStatus, original.variantStatus)
        XCTAssertEqual(card.introductionCohortId, original.introductionCohortId)
        XCTAssertEqual(card.selectionPolicy, original.selectionPolicy)
        XCTAssertEqual(card.priorityUntil, original.priorityUntil)
        XCTAssertEqual(card.introductionAvailableAt, original.introductionAvailableAt)
        XCTAssertEqual(card.state, original.state)
        XCTAssertEqual(card.createdAt, original.createdAt)
    }

    @MainActor
    private func assertReconciledCard(
        _ card: StudyCard,
        preservesMetadataFrom latest: StudyCard
    ) {
        XCTAssertEqual(card.id, latest.id)
        XCTAssertEqual(card.introductionCohortId, latest.introductionCohortId)
        XCTAssertEqual(card.selectionPolicy, latest.selectionPolicy)
        XCTAssertEqual(card.priorityUntil, latest.priorityUntil)
        XCTAssertEqual(card.introductionAvailableAt, latest.introductionAvailableAt)
        XCTAssertEqual(card.state, latest.state)
        XCTAssertEqual(card.createdAt, latest.createdAt)
    }

    @MainActor private static let presentationFixture: [String: Any] = [
        "version": 1,
        "front": [
            "mode": "text", "text": "projected", "ruby": NSNull(),
            "hint": NSNull(), "media": ["audio": NSNull(), "image": NSNull()],
            "autoplayAudio": false,
        ],
        "answer": [
            "heading": "answer", "ruby": NSNull(), "restored": NSNull(),
            "meaning": "meaning",
            "sentences": [
                "japanese": ["text": NSNull(), "ruby": NSNull()],
                "english": ["text": NSNull(), "ruby": NSNull()],
            ],
            "notes": [], "media": ["image": NSNull()],
            "audio": NSNull(), "pitchAccent": NSNull(),
        ],
    ]

    @MainActor
    private func makeCard(
        id: String = "local-id",
        syncId: String? = "local-sync-id",
        revision: Int? = 0,
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

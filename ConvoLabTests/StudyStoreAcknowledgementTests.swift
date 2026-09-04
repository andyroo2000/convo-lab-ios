import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testCreateReconcilesBackendNormalizedULIDWithoutDuplicate() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let body = try requestBody(request)
            let createRequest = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let canonicalID = try XCTUnwrap(createRequest["id"] as? String).lowercased()
            return try Self.cardAcknowledgement(for: request, id: canonicalID, statusCode: 201)
        }
        let store = makeEditorStore(container: container, client: client)

        try await store.createCard(
            expression: "正規化",
            reading: "せいきか",
            meaning: "normalization"
        )

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, records.first?.id.lowercased())
        XCTAssertEqual(store.libraryCards.count, 1)
        XCTAssertEqual(store.libraryCards.first?.id, records.first?.id)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testCreateAcknowledgementPreservesQueuedEditWhenUpdateIsRejected() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let createAttempts = LockedCounter()
        let client = makeCreateThenRejectClient(attempts: createAttempts)
        let store = makeEditorStore(container: container, client: client)

        try await store.createCard(
            expression: "最初",
            reading: "さいしょ",
            meaning: "original"
        )
        let created = try XCTUnwrap(store.libraryCards.first)
        var editedDraft = StudyCardDraft(card: created)
        editedDraft.cueText = "編集済み"
        editedDraft.answerExpression = "編集済み"
        editedDraft.answerMeaning = "edited"
        try await store.updateCard(created, draft: editedDraft)

        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(record.id, created.id.lowercased())
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "編集済み")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "edited")
        XCTAssertNotNil(record.locallyUpdatedAt)
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["cardUpdate"])
        XCTAssertEqual(pending.first?.resourceID, created.id.lowercased())
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testOlderUpdateAcknowledgementPreservesNewerRejectedEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000UE",
            expression: "元",
            masteryLevel: "guru"
        )
        try insertEditorCard(card, into: container)
        let patchAttempts = LockedCounter()
        let client = makeOverlappingUpdateClient(
            cardID: card.id,
            attempts: patchAttempts,
            sessionData: try emptyAcknowledgementSessionData(),
            cardType: card.cardType
        )
        let store = makeEditorStore(container: container, client: client)
        var firstDraft = StudyCardDraft(card: card)
        firstDraft.cueText = "一回目"
        firstDraft.answerExpression = "一回目"
        firstDraft.answerMeaning = "first"
        try await store.updateCard(card, draft: firstDraft)
        let firstEdit = try XCTUnwrap(store.libraryCards.first)
        var secondDraft = StudyCardDraft(card: firstEdit)
        secondDraft.cueText = "二回目"
        secondDraft.answerExpression = "二回目"
        secondDraft.answerMeaning = "second"
        try await store.updateCard(firstEdit, draft: secondDraft)

        await store.synchronize()

        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "二回目")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "second")
        XCTAssertEqual(persisted.masteryLevel, "guru")
        XCTAssertNotNil(record.locallyUpdatedAt)
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["cardUpdate"])
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testUpdateAcknowledgementPreservesPendingReviewMasteryProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makePendingReviewProjectionCard()
        try insertEditorCard(card, into: container)

        var draft = StudyCardDraft(card: card)
        draft.cueText = "Edited before review"
        let staleServerCard = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: draft.prompt(merging: card.prompt),
            answer: draft.answer(merging: card.answer),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            masteryLevel: "guru",
            createdAt: card.createdAt,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let staleServerData = try StorageCodec.encoder.encode(staleServerCard)
        let patchAttempts = LockedCounter()
        let reviewAttempts = LockedCounter()
        let cardID = card.id
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/\(cardID)":
                guard patchAttempts.next() > 1 else {
                    throw URLError(.notConnectedToInternet)
                }
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    staleServerData
                )
            case "/api/card-review-events/batch":
                _ = reviewAttempts.next()
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = makeEditorStore(container: container, client: client)

        try await store.updateCard(card, draft: draft)
        let edited = try XCTUnwrap(store.libraryCards.first)
        let eventID = await store.recordReview(
            card: edited,
            rating: .good,
            duration: nil,
            reviewedAt: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertNotNil(eventID)
        let optimisticReview = try persistedCard(in: container)
        XCTAssertNil(optimisticReview.masteryLevel)

        await store.synchronize()

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "Edited before review")
        XCTAssertEqual(persisted.state, optimisticReview.state)
        XCTAssertNil(persisted.masteryLevel)
        XCTAssertEqual(patchAttempts.current, 2)
        XCTAssertGreaterThanOrEqual(reviewAttempts.current, 2)
    }

    @MainActor
    private func makeCreateThenRejectClient(attempts: LockedCounter) -> APIClient {
        makeClient { request in
            guard request.url?.path == "/api/study/cards" else {
                return Self.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Rejected update"}"#.utf8)
                )
            }
            guard attempts.next() > 1 else {
                throw URLError(.notConnectedToInternet)
            }
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            let canonicalID = try XCTUnwrap(body["id"] as? String).lowercased()
            return try Self.cardAcknowledgement(for: request, id: canonicalID, statusCode: 201)
        }
    }

    @MainActor
    private func makeOverlappingUpdateClient(
        cardID: String,
        attempts: LockedCounter,
        sessionData: Data,
        cardType: String
    ) -> APIClient {
        makeClient { request in
            guard request.url?.path != "/api/study/session/start" else {
                return Self.response(data: sessionData)
            }
            let attempt = attempts.next()
            guard attempt > 2 else {
                throw URLError(.notConnectedToInternet)
            }
            guard attempt == 3 else {
                return Self.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Rejected newer update"}"#.utf8)
                )
            }
            return try Self.cardAcknowledgement(
                for: request,
                id: cardID,
                statusCode: 200,
                cardType: cardType
            )
        }
    }

    private static func cardAcknowledgement(
        for request: URLRequest,
        id: String,
        statusCode: Int,
        cardType: String? = nil
    ) throws -> (HTTPURLResponse, Data) {
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
        )
        let updatedAt = statusCode == 201 ? "2026-07-24T11:00:00Z" : "2026-07-24T11:01:00Z"
        let card: [String: Any] = [
            "id": id,
            "syncId": id,
            "noteId": NSNull(),
            "cardType": try cardType ?? XCTUnwrap(body["cardType"] as? String),
            "prompt": try XCTUnwrap(body["prompt"]),
            "answer": try XCTUnwrap(body["answer"]),
            "state": [
                "dueAt": NSNull(), "introducedAt": NSNull(), "failedAt": NSNull(),
                "queueState": "new", "scheduler": NSNull(), "source": [:],
            ],
            "answerAudioSource": "missing",
            "createdAt": "2026-07-24T11:00:00Z",
            "updatedAt": updatedAt,
        ]
        return Self.response(
            statusCode: statusCode,
            data: try JSONSerialization.data(withJSONObject: card)
        )
    }

    @MainActor
    private func emptyAcknowledgementSessionData() throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let object = try JSONSerialization.jsonObject(with: StorageCodec.encoder.encode(session))
        return try JSONSerialization.data(withJSONObject: ["data": object])
    }

    @MainActor
    private func makePendingReviewProjectionCard() -> StudyCard {
        makeCard(
            id: "01J000000000000000000000UR",
            expression: "Review pending",
            queueState: "review",
            scheduler: .object([
                "due": .string("2026-04-12T00:00:00.000Z"),
                "stability": .number(30),
                "difficulty": .number(6),
                "elapsed_days": .number(30),
                "scheduled_days": .number(30),
                "learning_steps": .number(0),
                "reps": .number(8),
                "lapses": .number(1),
                "state": .number(2),
                "last_review": .string("2026-03-13T00:00:00.000Z"),
            ]),
            masteryLevel: "guru"
        )
    }
}

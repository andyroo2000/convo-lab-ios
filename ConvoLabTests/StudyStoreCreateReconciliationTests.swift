import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testNormalizedCreateRewritesQueuedReviewToCanonicalCardID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let createAttempts = LockedCounter()
        let postedReviewCardIDs = LockedRequestPaths()
        let client = makeCanonicalReviewClient(
            createAttempts: createAttempts,
            postedReviewCardIDs: postedReviewCardIDs,
            sessionData: try emptyCreateSessionData()
        )
        let store = makeEditorStore(container: container, client: client)

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let clientCard = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: clientCard, rating: .good, duration: nil)

        XCTAssertEqual(
            Set(
                try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                    .map(\.kind)
            ),
            ["cardCreate", "review"]
        )

        await store.synchronize()

        XCTAssertEqual(postedReviewCardIDs.values, [clientCard.id.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertEqual(store.libraryCards.first?.id, clientCard.id.lowercased())
    }

    @MainActor
    func testCreateReconciliationKeepsReviewedCanonicalDuplicateState() async throws {
        let scenario = try makeReviewedDuplicateScenario()
        let container = scenario.container
        let serverID = scenario.serverID
        let canonicalServerCard = scenario.serverCard

        let serverCardData = try StorageCodec.encoder.encode(canonicalServerCard)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverCardData
                )
            case "/api/card-review-events/batch", "/api/study/session/start":
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let store = makeEditorStore(container: container, client: client)

        await store.recordReview(card: canonicalServerCard, rating: .good, duration: nil)
        let reviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == serverID }
        )

        await store.synchronize()

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, serverID)
        let persisted = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: try XCTUnwrap(records.first?.payload)
        )
        XCTAssertEqual(persisted.state.queueState, reviewedCard.state.queueState)
        XCTAssertEqual(persisted.state.scheduler, reviewedCard.state.scheduler)
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.dueAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.dueAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.introducedAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.introducedAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertFalse(try XCTUnwrap(records.first).isInActiveSession)
        XCTAssertTrue(store.cards.allSatisfy { $0.id != serverID })
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["review"])
        XCTAssertEqual(pending.first?.resourceID, serverID)
    }

    @MainActor
    private func makeCanonicalReviewClient(
        createAttempts: LockedCounter,
        postedReviewCardIDs: LockedRequestPaths,
        sessionData: Data
    ) -> APIClient {
        makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                guard createAttempts.next() > 2 else {
                    throw URLError(.notConnectedToInternet)
                }
                return try Self.normalizedCreateResponse(for: request)
            case "/api/card-review-events/batch":
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                let events = try XCTUnwrap(body["events"] as? [[String: Any]])
                postedReviewCardIDs.append(try XCTUnwrap(events.first?["card_id"] as? String))
                return Self.response(data: Data("{}".utf8))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
    }

    private static func normalizedCreateResponse(
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
        )
        let canonicalID = try XCTUnwrap(body["id"] as? String).lowercased()
        let card: [String: Any] = [
            "id": canonicalID,
            "syncId": canonicalID,
            "noteId": NSNull(),
            "cardType": try XCTUnwrap(body["cardType"]),
            "prompt": try XCTUnwrap(body["prompt"]),
            "answer": try XCTUnwrap(body["answer"]),
            "state": [
                "dueAt": NSNull(), "introducedAt": NSNull(), "failedAt": NSNull(),
                "queueState": "new", "scheduler": NSNull(), "source": [:],
            ],
            "answerAudioSource": "missing",
            "createdAt": "2026-07-24T11:00:00Z",
            "updatedAt": "2026-07-24T11:00:00Z",
        ]
        return Self.response(
            statusCode: 201,
            data: try JSONSerialization.data(withJSONObject: card)
        )
    }

    @MainActor
    private func emptyCreateSessionData() throws -> Data {
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

    private struct ReviewedDuplicateScenario {
        let container: ModelContainer
        let serverID: String
        let serverCard: StudyCard
    }

    @MainActor
    private func makeReviewedDuplicateScenario() throws -> ReviewedDuplicateScenario {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000RA"
        let serverID = clientID.lowercased()
        let clientCard = makeCard(id: clientID, expression: "同期", queueState: "new")
        let serverCard = StudyCard(
            id: serverID,
            syncId: serverID,
            noteId: clientCard.noteId,
            cardType: clientCard.cardType,
            prompt: clientCard.prompt,
            answer: clientCard.answer,
            state: clientCard.state,
            answerAudioSource: clientCard.answerAudioSource,
            createdAt: clientCard.createdAt,
            updatedAt: clientCard.updatedAt.addingTimeInterval(1)
        )
        let clientRecord = LocalCardRecord(
            card: clientCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(clientCard)
        )
        clientRecord.locallyUpdatedAt = clientCard.updatedAt
        container.mainContext.insert(clientRecord)
        container.mainContext.insert(
            LocalCardRecord(
                card: serverCard,
                userID: 1,
                queueIndex: 1,
                payload: try StorageCodec.encoder.encode(serverCard)
            )
        )
        let request = CreateStudyCardRequest(
            id: clientID,
            cardType: clientCard.cardType,
            prompt: clientCard.prompt,
            answer: clientCard.answer
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "cardCreate",
                userID: 1,
                resourceID: clientID,
                payload: try StorageCodec.encoder.encode(request)
            )
        )
        try container.mainContext.save()
        return ReviewedDuplicateScenario(
            container: container,
            serverID: serverID,
            serverCard: serverCard
        )
    }
}

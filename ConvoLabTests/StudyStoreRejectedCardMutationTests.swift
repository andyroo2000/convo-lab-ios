import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRejectedCardCreateSurfacesItsDependentReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: offlineClient, context: container.mainContext)
        )

        try await store.createCard(expression: "拒否", reading: "きょひ", meaning: "reject")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
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
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        MockURLProtocol.handler = { request in
            let path = request.url?.path
            let status: Int
            let data: Data
            switch path {
            case "/api/study/cards":
                status = 422
                data = Data(#"{"message":"Invalid card"}"#.utf8)
            case "/api/card-review-events/batch":
                status = 404
                data = Data(#"{"message":"Card not found"}"#.utf8)
            default:
                status = 200
                data = sessionData
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map(\.kind)), ["cardCreate", "review"])
        XCTAssertTrue(pending.allSatisfy { $0.lastError != nil })
        XCTAssertEqual(store.quarantinedMutationCount, 2)
    }

    @MainActor
    func testDiscardingRejectedCardDeleteReleasesServerReconciliation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "残す"
        )
        let delete = PendingMutation(
            kind: "cardDelete",
            userID: 1,
            resourceID: "SERVER-CARD-ID",
            payload: Data()
        )
        delete.lastError = "HTTP 409: Delete conflict"
        container.mainContext.insert(delete)
        // Match deleteCard(_:)'s optimistic state: the local replica is gone
        // before the server rejects the queued deletion.
        try container.mainContext.save()

        let sessionData = try sessionResponseData(cards: [card])
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/batch":
                let cardObject = try JSONSerialization.jsonObject(with: cardData)
                return Self.response(data: try JSONSerialization.data(
                    withJSONObject: ["cards": [cardObject]]
                ))
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        XCTAssertEqual(store.failedStudyChanges.map(\.kind), [.cardDelete])
        XCTAssertTrue(store.libraryCards.isEmpty)

        try await store.discardFailedStudyChange(id: delete.id)

        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
    }

    @MainActor
    func testDiscardingRejectedCardUpdateRestoresCanonicalServerContent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F3",
            expression: "サーバー"
        )
        let localCard = makeCard(
            id: serverCard.id,
            expression: "破棄する編集"
        )
        let record = LocalCardRecord(
            card: localCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(localCard)
        )
        record.locallyUpdatedAt = .now
        let update = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: localCard.prompt,
                answer: localCard.answer
            ))
        )
        update.lastError = "HTTP 422: Invalid card"
        container.mainContext.insert(record)
        container.mainContext.insert(update)
        try container.mainContext.save()

        let cardData = try StorageCodec.encoder.encode(serverCard)
        let sessionData = try sessionResponseData(cards: [serverCard])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/batch":
                let cardObject = try JSONSerialization.jsonObject(with: cardData)
                return Self.response(data: try JSONSerialization.data(
                    withJSONObject: ["cards": [cardObject]]
                ))
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        XCTAssertEqual(store.libraryCards.first?.promptText, "破棄する編集")

        try await store.discardFailedStudyChange(id: update.id)

        XCTAssertEqual(store.libraryCards.first?.promptText, "サーバー")
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testRevisionConflictRestoresCurrentServerCardAndQuarantinesEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let loadedCard = makeCard(
            id: "01J00000000000000000000C0",
            revision: 3,
            expression: "読み込み時"
        )
        let currentServerCard = makeCard(
            id: loadedCard.id,
            revision: 4,
            expression: "サーバー最新"
        )
        let record = LocalCardRecord(
            card: loadedCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(loadedCard)
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
        let currentCardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(currentServerCard)
        )
        let conflictData = try JSONSerialization.data(withJSONObject: [
            "code": "card_revision_conflict",
            "message": "Study card content changed since it was loaded.",
            "card": currentCardObject,
        ])
        let loadedCardID = loadedCard.id
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(loadedCardID)")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try requestBody(request)
            let update = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(update["expectedRevision"] as? Int, 3)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                conflictData
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        try await store.updateCard(
            loadedCard,
            prompt: "ローカル編集",
            reading: "",
            answer: "local edit"
        )

        let restored = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(restored.promptText, "サーバー最新")
        XCTAssertEqual(restored.revision, 4)
        XCTAssertNil(record.locallyUpdatedAt)
        let persisted = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        XCTAssertEqual(persisted.promptText, "サーバー最新")
        XCTAssertEqual(persisted.revision, 4)
        let failure = try XCTUnwrap(store.failedStudyChanges.first)
        XCTAssertEqual(failure.kind, .cardUpdate)
        XCTAssertTrue(failure.errorMessage.contains("card_revision_conflict"))
        XCTAssertFalse(failure.isRetryable)
    }

    @MainActor
    func testDiscardingOlderRejectedCardUpdatePreservesNewerPendingEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F7",
            expression: "サーバー"
        )
        let localCard = makeCard(
            id: serverCard.id,
            expression: "最新の編集"
        )
        let record = LocalCardRecord(
            card: localCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(localCard)
        )
        record.locallyUpdatedAt = .now
        let rejectedUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: serverCard.prompt,
                answer: serverCard.answer
            ))
        )
        rejectedUpdate.lastError = "HTTP 422: Invalid card"
        let newerUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id.uppercased(),
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: localCard.prompt,
                answer: localCard.answer
            ))
        )
        container.mainContext.insert(record)
        container.mainContext.insert(rejectedUpdate)
        container.mainContext.insert(newerUpdate)
        try container.mainContext.save()

        let cardData = try StorageCodec.encoder.encode(serverCard)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: canonicalData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        try await store.discardFailedStudyChange(id: rejectedUpdate.id)

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.id), [newerUpdate.id])
        XCTAssertNotNil(record.locallyUpdatedAt)
        let retainedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        XCTAssertEqual(retainedCard.promptText, "最新の編集")
        XCTAssertEqual(store.libraryCards.first?.promptText, "最新の編集")
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedCardUpdateRemovesCardMissingFromServer() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000F5",
            expression: "既に削除"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.locallyUpdatedAt = .now
        let update = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: card.prompt,
                answer: card.answer
            ))
        )
        update.lastError = "HTTP 404: Card not found"
        let dependentReview = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id.uppercased(),
            payload: Data()
        )
        container.mainContext.insert(record)
        container.mainContext.insert(update)
        container.mainContext.insert(dependentReview)
        try container.mainContext.save()

        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        try await store.discardFailedStudyChange(id: update.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedCardCreateRemovesLocalCardAndDependentChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.createCard(expression: "仮", reading: "かり", meaning: "temporary")
        let card = try XCTUnwrap(store.libraryCards.first)
        let create = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardCreate" })
        )
        create.lastError = "HTTP 422: Invalid card"
        let dependentUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id.uppercased(),
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: card.prompt,
                answer: card.answer
            ))
        )
        container.mainContext.insert(dependentUpdate)
        try container.mainContext.save()
        store.reloadFailedStudyChanges()

        try await store.discardFailedStudyChange(id: create.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testRetryingRejectedCardUpdateDrainsCardOutbox() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F4",
            expression: "再送信"
        )
        let payload = try StorageCodec.encoder.encode(UpdateStudyCardRequest(
            prompt: serverCard.prompt,
            answer: serverCard.answer
        ))
        let record = LocalCardRecord(
            card: serverCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(serverCard)
        )
        record.locallyUpdatedAt = .now
        let mutation = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: payload
        )
        mutation.lastError = "HTTP 422: Invalid card"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let serverCardID = serverCard.id
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(serverCardID)")
            XCTAssertEqual(request.httpMethod, "PATCH")
            return Self.response(data: serverCardData)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testRejectedCardMutationDoesNotBlockNewerCardMutation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.createCard(expression: "犬", reading: "いぬ", meaning: "dog")
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let offlinePending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.kind.hasPrefix("card") }
        let rejectedAttemptsBeforeSync = try XCTUnwrap(offlinePending.first).attemptCount
        let acceptedCard = try XCTUnwrap(store.cards.last)
        let acceptedCardData = try StorageCodec.encoder.encode(acceptedCard)
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
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let cardRequestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/study/session/start" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            }
            let status = cardRequestCounter.next() == 1 ? 422 : 201
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 422
                    ? Data(#"{"message":"Invalid card"}"#.utf8)
                    : acceptedCardData
            )
        }

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
            .filter { $0.kind.hasPrefix("card") }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, rejectedAttemptsBeforeSync + 1)
        XCTAssertNotNil(pending.first?.lastError)
    }
}

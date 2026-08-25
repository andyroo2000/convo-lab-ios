import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRefreshDeDuplicatesCaseCanonicalizedServerCardIDs() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000009", expression: "重複")
        let canonicalizedDuplicate = makeCard(
            id: card.id.lowercased(),
            expression: "重複"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [card, canonicalizedDuplicate]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                sessionData
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<LocalCardRecord>()),
            1
        )
    }

    @MainActor
    func testRefreshOnlyMarksCardsPreparedWhenEveryDeclaredMediaFileExists() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let missingMediaCard = makeCard(
            id: "01J00000000000000000000006",
            expression: "未取得",
            mediaURL: "/api/study/media/missing"
        )
        let downloadedMediaCard = makeCard(
            id: "01J00000000000000000000007",
            expression: "取得済み",
            mediaURL: "/api/study/media/available"
        )
        let textOnlyCard = makeCard(
            id: "01J00000000000000000000008",
            expression: "文字のみ"
        )
        let staleRecord = LocalCardRecord(
            card: missingMediaCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(missingMediaCard)
        )
        staleRecord.mediaPreparedAt = .now
        container.mainContext.insert(staleRecord)
        try container.mainContext.save()

        let session = StudySession(
            overview: StudyOverview(
                dueCount: 3,
                newCount: 0,
                reviewCount: 3,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [missingMediaCard, downloadedMediaCard, textOnlyCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            let path = request.url?.path
            if path == "/api/study/session/start" {
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
            let available = path == "/api/study/media/available"
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: available ? 200 : 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                available ? Data("audio".utf8) : Data()
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.preparedCardCount, 2)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertNil(records.first(where: { $0.id == missingMediaCard.id })?.mediaPreparedAt)
        XCTAssertNotNil(
            records.first(where: { $0.id == downloadedMediaCard.id })?.mediaPreparedAt
        )
        XCTAssertNotNil(records.first(where: { $0.id == textOnlyCard.id })?.mediaPreparedAt)
    }

    @MainActor
    func testDeletingOfflineCreatedCardDoesNotResurrectIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        try await store.createCard(expression: "犬", reading: "いぬ", meaning: "dog")
        let card = try XCTUnwrap(store.cards.first)
        let cardData = try StorageCodec.encoder.encode(card)

        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                cardData
            )
        }

        try await store.deleteCard(card)

        let localCards = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(localCards.isEmpty)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
    }

    @MainActor
    func testRefreshDoesNotResurrectCardWithAliasedQuarantinedDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "削除"
        )
        let delete = PendingMutation(
            kind: "cardDelete",
            userID: 1,
            resourceID: "SERVER-CARD-ID",
            payload: Data()
        )
        delete.lastError = "HTTP 409: Delete conflict"
        container.mainContext.insert(delete)
        try container.mainContext.save()

        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: [card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                envelopeData
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
    }

    @MainActor
    func testCardUpdatePreservesReadingAndServerManagedPayloadFields() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = StudyCard(
            id: "01J00000000000000000000004",
            noteId: nil,
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("古い文"),
                "cueReading": .string("古[ふる]い文[ぶん]"),
                "cueAudio": .object(["url": .string("/api/media/prompt")]),
            ]),
            answer: .object([
                "expression": .string("古い文"),
                "meaning": .string("old sentence"),
                "answerAudio": .object(["url": .string("/api/media/answer")]),
                "notes": .string("Keep this note"),
            ]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "generated",
            masteryLevel: "guru",
            createdAt: .now,
            updatedAt: .now
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.updateCard(
            card,
            prompt: "新しい文",
            reading: "新[あたら]しい文[ぶん]",
            answer: "new sentence"
        )

        let updated = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(updated.prompt["cueText"]?.stringValue, "新しい文")
        XCTAssertEqual(updated.prompt["cueReading"]?.stringValue, "新[あたら]しい文[ぶん]")
        XCTAssertEqual(updated.prompt["cueAudio"], card.prompt["cueAudio"])
        XCTAssertEqual(updated.answer["meaning"]?.stringValue, "new sentence")
        XCTAssertEqual(updated.answer["answerAudio"], card.answer["answerAudio"])
        XCTAssertEqual(updated.answer["notes"]?.stringValue, "Keep this note")
        XCTAssertEqual(updated.masteryLevel, "guru")

        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardUpdate" })
        )
        let request = try StorageCodec.decoder.decode(
            UpdateStudyCardRequest.self,
            from: mutation.payload
        )
        XCTAssertEqual(request.prompt["cueAudio"], card.prompt["cueAudio"])
        XCTAssertEqual(request.answer["answerAudio"], card.answer["answerAudio"])
    }

    @MainActor
    func testRefreshKeepsLocallyDirtyCardInActiveQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let card = try XCTUnwrap(store.cards.first)
        let initialRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        initialRecord.queueIndex = 42
        try container.mainContext.save()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 1,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                envelopeData
            )
        }

        try await store.refreshSession()

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(try XCTUnwrap(records.first).isInActiveSession)
        XCTAssertNotNil(records.first?.locallyUpdatedAt)
        XCTAssertEqual(records.first?.queueIndex, 0)
    }
}

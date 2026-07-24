import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class StudyStoreTests: XCTestCase {
    @MainActor
    func testPitchAccentResolutionPersistsServerEnrichmentWithoutChangingSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let original = makeCard(
            id: "compatibility-card-id",
            expression: "会社"
        )
        let card = StudyCard(
            id: original.id,
            syncId: "01J000000000000000000000PA",
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer,
            state: original.state,
            answerAudioSource: original.answerAudioSource,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let resolvedAnswer = card.answer.replacingObjectValues([
            "pitchAccent": .object([
                "status": .string("resolved"),
                "expression": .string("会社"),
                "reading": .string("かいしゃ"),
                "pitchNum": .number(0),
                "morae": .array([.string("か"), .string("い"), .string("しゃ")]),
                "pattern": .array([.number(0), .number(1), .number(1)]),
                "patternName": .string("平板"),
                "source": .string("kanjium"),
                "resolvedBy": .string("local-reading"),
            ]),
        ])
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: resolvedAnswer,
            state: .init(
                dueAt: .distantFuture,
                introducedAt: .now,
                failedAt: .now,
                queueState: "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/study/cards/01J000000000000000000000PA/pitch-accent"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        await store.resolvePitchAccent(for: card)

        let updated = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(updated.state, card.state)
        XCTAssertEqual(updated.presentation.back.pitchAccent?.reading, "かいしゃ")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.presentation.back.pitchAccent?.pattern, [0, 1, 1])
    }

    @MainActor
    func testPersistedUnresolvedPitchAccentDoesNotRetryOnEveryReveal() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let original = makeCard(
            id: "01J000000000000000000000PU",
            expression: "固有名詞"
        )
        let card = StudyCard(
            id: original.id,
            syncId: original.syncId,
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer.replacingObjectValues([
                "pitchAccent": .object([
                    "status": .string("unresolved"),
                    "reason": .string("not-found"),
                ]),
            ]),
            state: original.state,
            answerAudioSource: original.answerAudioSource,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.badServerResponse)
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        await store.resolvePitchAccent(for: card)
        await store.resolvePitchAccent(for: card)

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertNil(store.cards.first?.presentation.back.pitchAccent)
    }

    @MainActor
    func testPitchAccentResolutionPreservesReviewThatFinishesDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PR",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let serverCard = cardWithResolvedPitchAccent(card)
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        let resolution = Task { await store.resolvePitchAccent(for: card) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        let reviewedAt = Date.now
        let reviewed = card.applyingReview(.good, at: reviewedAt)
        let reviewedCard = StudyCard(
            id: reviewed.id,
            syncId: reviewed.syncId,
            noteId: reviewed.noteId,
            cardType: reviewed.cardType,
            prompt: reviewed.prompt.replacingObjectValues([
                "cueText": .string("編集した会社"),
            ]),
            answer: reviewed.answer.replacingObjectValues([
                "meaning": .string("edited company"),
            ]),
            state: reviewed.state,
            answerAudioSource: reviewed.answerAudioSource,
            createdAt: reviewed.createdAt,
            updatedAt: reviewedAt
        )
        let reviewedRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        reviewedRecord.payload = try StorageCodec.encoder.encode(reviewedCard)
        reviewedRecord.isInActiveSession = false
        reviewedRecord.locallyUpdatedAt = reviewedAt
        try container.mainContext.save()
        gate.release()
        await resolution.value

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state.queueState, reviewedCard.state.queueState)
        XCTAssertEqual(persisted.state.scheduler, reviewedCard.state.scheduler)
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.dueAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.dueAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(persisted.presentation.back.pitchAccent?.reading, "かいしゃ")
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "編集した会社")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "edited company")
        XCTAssertFalse(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
            ).isInActiveSession
        )
        XCTAssertNotNil(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
            ).locallyUpdatedAt
        )
    }

    @MainActor
    func testPitchAccentResolutionDoesNotResurrectCardDeletedDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PD",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let responseData = try StorageCodec.encoder.encode(cardWithResolvedPitchAccent(card))
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        let resolution = Task { await store.resolvePitchAccent(for: card) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        container.mainContext.insert(
            PendingMutation(kind: "cardDelete", resourceID: card.id, payload: Data())
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        container.mainContext.delete(record)
        try container.mainContext.save()
        gate.release()
        await resolution.value

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
    }

    @MainActor
    func testCardBecomingDueDoesNotReplaceVisibleCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let visibleCard = makeCard(
            id: "01J00000000000000000000015",
            expression: "新しい",
            queueState: "new"
        )
        let dueAt = Date.now.addingTimeInterval(60)
        let futureReview = makeCard(
            id: "01J00000000000000000000016",
            expression: "復習",
            dueAt: dueAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: visibleCard,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(visibleCard)
            )
        )
        let futureRecord = LocalCardRecord(
            card: futureReview,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(futureReview)
        )
        futureRecord.isInActiveSession = false
        container.mainContext.insert(futureRecord)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activateOfflineDueCards(at: dueAt)

        XCTAssertEqual(store.cards.map(\.id), [visibleCard.id, futureReview.id])
    }

    @MainActor
    func testDueActivationTimerReactivatesCardWhileStoreRemainsOpen() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date.now.addingTimeInterval(1.5)
        let card = makeCard(
            id: "01J00000000000000000000017",
            expression: "時間",
            dueAt: dueAt
        )
        let record = LocalCardRecord(
            card: card,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        XCTAssertTrue(store.cards.isEmpty)
        for _ in 0..<30 where store.cards.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(store.cards.map(\.id), [card.id])
    }

    @MainActor
    func testAgainReturnsWhenDueOfflineAndLaterGoodClearsFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000014",
            expression: "繰り返す"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let firstReviewAt = Date(timeIntervalSince1970: 1_800_000_000)

        await store.recordReview(
            card: card,
            rating: .again,
            duration: nil,
            reviewedAt: firstReviewAt
        )

        let againDueAt = try XCTUnwrap(store.libraryCards.first?.state.dueAt)
        XCTAssertEqual(againDueAt, firstReviewAt.addingTimeInterval(10 * 60))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.failedDue, 1)

        store.activateOfflineDueCards(at: againDueAt.addingTimeInterval(-1))
        XCTAssertTrue(store.cards.isEmpty)

        store.activateOfflineDueCards(at: againDueAt)
        let relearningCard = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(relearningCard.state.queueState, "relearning")
        XCTAssertNotNil(relearningCard.state.failedAt)

        await store.recordReview(
            card: relearningCard,
            rating: .good,
            duration: nil,
            reviewedAt: againDueAt
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.failedDue, 0)

        let relaunched = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        XCTAssertTrue(relaunched.cards.isEmpty)
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)

        let goodDueAt = try XCTUnwrap(relaunched.libraryCards.first?.state.dueAt)
        XCTAssertEqual(goodDueAt, againDueAt.addingTimeInterval(3 * 24 * 60 * 60))
        relaunched.activateOfflineDueCards(at: goodDueAt)
        XCTAssertEqual(relaunched.cards.map(\.id), [card.id])
        XCTAssertEqual(relaunched.cards.first?.state.queueState, "review")
        XCTAssertNil(relaunched.cards.first?.state.failedAt)
    }

    @MainActor
    func testFirstTimeOfflineFailureSurvivesRelaunchAndStaleServerRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000011", expression: "再学習")
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .again, duration: nil)

        XCTAssertEqual(store.sessionCounts.failedDue, 1)
        XCTAssertTrue(store.cards.isEmpty)

        let relaunched = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 1)
        XCTAssertTrue(relaunched.cards.isEmpty)

        let staleSession = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 0
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(staleSession)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/study/session/start")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        try await relaunched.refreshSession()

        XCTAssertTrue(relaunched.cards.isEmpty)
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 1)
    }

    @MainActor
    func testCorruptedPendingReviewDoesNotBlockSessionRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewedCard = makeCard(
            id: "01J00000000000000000000012",
            expression: "破損"
        )
        let availableCard = makeCard(
            id: "01J00000000000000000000013",
            expression: "利用可能"
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "review",
                resourceID: reviewedCard.id,
                payload: Data("not-json".utf8)
            )
        )
        try container.mainContext.save()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 2,
                newCount: 0,
                reviewCount: 2,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0
            ),
            cards: [reviewedCard, availableCard]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/session/start")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), [availableCard.id])
        XCTAssertEqual(store.overview?.dueCount, 2)
    }

    @MainActor
    func testReviewingFailedCardOptimisticallyUpdatesSessionCounts() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let failedCard = StudyCard(
            id: "98f42a62-8303-410e-ad4d-5a69c55911bb",
            syncId: "01J00000000000000000000010",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("失敗")]),
            answer: .object(["meaning": .string("failure")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: .now,
                queueState: "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 1
            ),
            cards: [failedCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let expectedSyncID = failedCard.syncId
        let client = makeClient { request in
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
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            let body = try requestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.first?["card_id"] as? String, expectedSyncID)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"data":[]}"#.utf8)
            )
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )
        try await store.refreshSession()
        XCTAssertEqual(store.sessionCounts.failedDue, 1)

        await store.recordReview(card: failedCard, rating: .good, duration: nil)

        XCTAssertEqual(
            store.sessionCounts,
            StudySessionCounts(failedDue: 0, reviewRemaining: 0, newRemaining: 0)
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testRefreshDeDuplicatesRepeatedServerCardIDs() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000009", expression: "重複")
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [card, card]
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
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
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
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
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
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
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
    func testRefreshDoesNotResurrectCardWithQuarantinedDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000003", expression: "削除")
        let delete = PendingMutation(kind: "cardDelete", resourceID: card.id, payload: Data())
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
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
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
            createdAt: .now,
            updatedAt: .now
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
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
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let card = try XCTUnwrap(store.cards.first)
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
    }

    @MainActor
    func testRejectedReviewDoesNotBlockNewerReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let rejectedCard = makeCard(id: "01J00000000000000000000001", expression: "犬")
        let acceptedCard = makeCard(id: "01J00000000000000000000002", expression: "猫")
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            let status = requestCounter.next() == 1 ? 422 : 204
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 422 ? Data(#"{"message":"Invalid review"}"#.utf8) : Data()
            )
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )

        await store.recordReview(card: rejectedCard, rating: .good, duration: nil)
        await store.recordReview(card: acceptedCard, rating: .good, duration: nil)

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
            .filter { $0.kind == "review" }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.resourceID, rejectedCard.id)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testNewCardCreateFlushesBeforeItsReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(api: offlineClient, context: container.mainContext)
        )

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
        let locallyReviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == card.id }
        )
        let serverCreatedAt = card.createdAt.addingTimeInterval(-60)
        let serverUpdatedAt = card.updatedAt.addingTimeInterval(1)
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: "server-note-id",
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: card.state,
            answerAudioSource: "generated",
            createdAt: serverCreatedAt,
            updatedAt: serverUpdatedAt
        )
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let decodedServerCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: serverCardData
        )
        let decodedReviewedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: StorageCodec.encoder.encode(locallyReviewedCard)
        )
        XCTAssertEqual(
            Set(
                try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                    .map(\.kind)
            ),
            ["cardCreate", "review"]
        )

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
        let paths = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let status = path == "/api/study/session/start" ? 200 : 201
            let data: Data
            switch path {
            case "/api/study/cards":
                data = serverCardData
            case "/api/study/session/start":
                data = sessionData
            default:
                data = Data(#"{"data":[]}"#.utf8)
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

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards",
                "/api/card-review-events/batch",
                "/api/study/session/start",
            ]
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(record.serverUpdatedAt, decodedServerCard.updatedAt)
        XCTAssertEqual(storedCard.noteId, "server-note-id")
        XCTAssertEqual(storedCard.answerAudioSource, "generated")
        XCTAssertEqual(storedCard.createdAt, decodedServerCard.createdAt)
        XCTAssertEqual(storedCard.state, decodedReviewedCard.state)
        XCTAssertEqual(storedCard.updatedAt, decodedReviewedCard.updatedAt)
    }

    @MainActor
    func testRejectedCardCreateSurfacesItsDependentReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(api: offlineClient, context: container.mainContext)
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
    func testQuarantinedReviewDoesNotBlockCardSyncOrSessionRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )
        let rejectedReviewCard = makeCard(
            id: "01J00000000000000000000005",
            expression: "失敗"
        )
        await store.recordReview(card: rejectedReviewCard, rating: .good, duration: nil)
        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let createdCard = try XCTUnwrap(store.libraryCards.last)
        let createdCardData = try StorageCodec.encoder.encode(createdCard)
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 1,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [rejectedReviewCard, createdCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])

        MockURLProtocol.handler = { request in
            let path = request.url?.path
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Invalid review"}"#.utf8)
                )
            }
            if path == "/api/study/cards" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    createdCardData
                )
            }
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

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.filter { $0.kind == "review" }.count, 1)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
        XCTAssertEqual(store.overview?.newCount, 1)
        XCTAssertEqual(Set(store.cards.map(\.id)), [rejectedReviewCard.id, createdCard.id])
        XCTAssertNotNil(store.lastSyncAt)
    }

    @MainActor
    func testRejectedCardMutationDoesNotBlockNewerCardMutation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
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

    @MainActor
    func testOfflineReviewedCardStaysOutOfQueueAfterRelaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000018",
            expression: "鳥"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .good, duration: .milliseconds(750))
        let relaunchedStore = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
        XCTAssertEqual(relaunchedStore.libraryCards.map(\.id), [card.id])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
        let reviewMutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "review" })
        )
        let storedReview = try JSONSerialization.jsonObject(
            with: reviewMutation.payload
        ) as? [String: Any]
        let event = try XCTUnwrap(storedReview?["event"])
        let eventData = try JSONSerialization.data(withJSONObject: event)
        let review = try StorageCodec.decoder.decode(
            ReviewBatchRequest.Event.self,
            from: eventData
        )
        XCTAssertEqual(review.durationMilliseconds, 750)
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDelayedPitchClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedPitchURLProtocol.responseData = responseData
        DelayedPitchURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedPitchURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeCard(
        id: String,
        expression: String,
        mediaURL: String? = nil,
        queueState: String = "review",
        dueAt: Date? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let mediaURL {
            prompt["cueAudio"] = .object(["url": .string(mediaURL)])
        }
        return StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(prompt),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
                introducedAt: nil,
                failedAt: nil,
                queueState: queueState,
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    private func cardWithResolvedPitchAccent(_ card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "pitchAccent": .object([
                    "status": .string("resolved"),
                    "expression": .string("会社"),
                    "reading": .string("かいしゃ"),
                    "morae": .array([.string("か"), .string("い"), .string("しゃ")]),
                    "pattern": .array([.number(0), .number(1), .number(1)]),
                    "patternName": .string("平板"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
    }

    @MainActor
    private func persistedCard(
        in container: ModelContainer
    ) throws -> StudyCard {
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        return try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class LockedRequestPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

final class LockedRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class DelayedPitchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/pitch-accent") == true else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let responseData = Self.responseData
        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

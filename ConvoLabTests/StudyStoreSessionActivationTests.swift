import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
private final class TestStudyDueActivationScheduler: StudyDueActivationScheduling {
    private(set) var now: Date
    private(set) var deadline: Date?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private var action: (@MainActor @Sendable () -> Void)?

    init(now: Date) {
        self.now = now
    }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        scheduleCount += 1
        self.deadline = deadline
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        deadline = nil
        action = nil
    }

    @discardableResult
    func fire() -> Bool {
        guard let deadline, let action else { return false }
        now = deadline
        self.deadline = nil
        self.action = nil
        action()
        return true
    }
}

extension StudyStoreTests {
    private struct OfflineCardCreationCase {
        let cardType: StudyCardDraft.CardType
        let cueText: String
        let cueMeaning: String
        let answerExpression: String
        let answerReading: String
        let answerMeaning: String
        let promptKey: String
        let promptValue: String
        let answerKey: String
        let answerValue: String
    }

    private struct OverlappingSessionResponses {
        let firstReview: Data
        let secondReview: Data
        let lesson: Data
        var holdLesson = false
    }

    @MainActor
    func testOfflineCardCreationQueuesTypeAwarePayloads() async throws {
        let cases = [
            OfflineCardCreationCase(
                cardType: .cloze,
                cueText: "毎日{{c1::勉強する}}。",
                cueMeaning: "daily habit",
                answerExpression: "毎日勉強する。",
                answerReading: "毎日[まいにち]勉強[べんきょう]する。",
                answerMeaning: "I study every day.",
                promptKey: "clozeText",
                promptValue: "毎日{{c1::勉強する}}。",
                answerKey: "restoredText",
                answerValue: "毎日勉強する。"
            ),
            OfflineCardCreationCase(
                cardType: .production,
                cueText: "to learn",
                cueMeaning: "",
                answerExpression: "学ぶ",
                answerReading: "学[まな]ぶ",
                answerMeaning: "to learn",
                promptKey: "cueText",
                promptValue: "to learn",
                answerKey: "expression",
                answerValue: "学ぶ"
            ),
        ]
        var thrownErrors: [String] = []

        for testCase in cases {
            do {
                try await assertOfflineCardCreation(testCase)
            } catch {
                thrownErrors.append("\(testCase.cardType.rawValue): \(error)")
            }
        }

        XCTAssertTrue(thrownErrors.isEmpty, thrownErrors.joined(separator: "\n"))
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
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(visibleCard)
            )
        )
        let futureRecord = LocalCardRecord(
            card: futureReview,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(futureReview)
        )
        futureRecord.isInActiveSession = false
        container.mainContext.insert(futureRecord)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = makeSessionStore(
            in: container,
            client: client,
            mediaCache: mediaCache
        )

        store.activateOfflineDueCards(at: dueAt)

        XCTAssertEqual(store.cards.map(\.id), [visibleCard.id, futureReview.id])
    }

    @MainActor
    func testActivationRestoresLastOverviewWithoutNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let overview = StudyOverview(
            dueCount: 7,
            newCount: 5,
            reviewCount: 120,
            totalCards: 4103,
            newCardsPerDay: 10,
            newCardsAvailableToday: 5,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 90
        )
        container.mainContext.insert(
            LocalStudyOverviewSnapshot(
                userID: 1,
                payload: try StorageCodec.encoder.encode(overview)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }

        let store = makeSessionStore(in: container, client: client)

        XCTAssertEqual(store.overview?.dueCount, 7)
        XCTAssertEqual(store.overview?.newCount, 5)
        XCTAssertEqual(store.overview?.totalCards, 4103)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 5)
        store.deactivate()
    }

    @MainActor
    func testLoadNextReviewBatchPromotesNewlyDueOfflineReserveBeforeSyncing() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let futureCard = makeCard(
            id: "01J00000000000000000000019",
            expression: "次",
            dueAt: Date.now.addingTimeInterval(60)
        )
        let record = LocalCardRecord(
            card: futureCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(futureCard)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let requestedPaths = LockedRequestPaths()
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "")
            throw URLError(.notConnectedToInternet)
        }
        let store = makeSessionStore(in: container, client: client)
        XCTAssertTrue(store.cards.isEmpty)

        let readyCard = makeCard(
            id: futureCard.id,
            expression: "次",
            dueAt: Date.now.addingTimeInterval(-1)
        )
        record.payload = try StorageCodec.encoder.encode(readyCard)
        try container.mainContext.save()

        await store.loadNextReviewBatch()

        XCTAssertEqual(store.cards.map(\.id), [readyCard.id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertTrue(requestedPaths.values.isEmpty)
        XCTAssertTrue(record.isInActiveSession)
    }

    @MainActor
    func testLoadNextReviewBatchFallsBackToServerWhenOfflineReserveIsEmpty() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J0000000000000000000001A",
            expression: "同期",
            dueAt: Date.now.addingTimeInterval(-1)
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: [serverCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
        let requestedPaths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            let data: Data
            switch path {
            case "/api/sync/feed":
                data = Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                )
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return try Self.response(for: request, data: data)
        }
        let store = makeSessionStore(in: container, client: client)

        await store.loadNextReviewBatch()

        XCTAssertEqual(store.cards.map(\.id), [serverCard.id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(
            requestedPaths.values,
            [
                "/api/sync/feed",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
    }

    @MainActor
    func testSuccessfulSynchronizationDoesNotClearBlockedStorageWriteWarning() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
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
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
        let client = makeClient { request in
            let data: Data
            switch request.url?.path {
            case "/api/sync/feed":
                data = Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                )
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return try Self.response(for: request, data: data)
        }
        let store = makeSessionStore(
            in: container,
            client: client,
            storageMode: .temporary
        )

        let eventID = await store.recordReview(
            card: makeCard(id: "blocked-review", expression: "保存不可"),
            rating: .good,
            duration: nil
        )
        await store.synchronize()

        XCTAssertNil(eventID)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            StorageWriteUnavailableError(domain: .study).localizedDescription
        )
    }

    @MainActor
    func testOfflineDueActivationDoesNotResurrectAliasedPendingDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "削除",
            dueAt: .now
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: "SERVER-CARD-ID",
                payload: Data()
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = makeSessionStore(
            in: container,
            client: client,
            mediaCache: mediaCache
        )

        store.activateOfflineDueCards(at: .now)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testOfflineDueActivationDoesNotDuplicateAnActiveCardAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let activeCard = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "学習中",
            dueAt: .now
        )
        let activeRecord = LocalCardRecord(
            card: activeCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(activeCard)
        )
        activeRecord.isInActiveSession = true
        let aliasedCard = makeCard(
            id: "SERVER-CARD-ID",
            expression: "重複",
            dueAt: .now
        )
        let aliasedRecord = LocalCardRecord(
            card: aliasedCard,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(aliasedCard)
        )
        aliasedRecord.isInActiveSession = false
        container.mainContext.insert(activeRecord)
        container.mainContext.insert(aliasedRecord)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = makeSessionStore(in: container, client: client)

        store.activateOfflineDueCards(at: .now)

        XCTAssertEqual(store.cards.map(\.id), ["local-card-id"])
        XCTAssertFalse(aliasedRecord.isInActiveSession)
    }

    @MainActor
    func testDueActivationTimerReactivatesCardWhileStoreRemainsOpen() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dueAt = now.addingTimeInterval(90)
        let card = makeCard(
            id: "01J00000000000000000000017",
            expression: "時間",
            dueAt: dueAt
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache,
            dueActivationScheduler: scheduler
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(scheduler.deadline, dueAt)
        XCTAssertTrue(scheduler.fire())

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertNil(scheduler.deadline)
        store.deactivate()
        await Task.yield()
    }

    @MainActor
    func testDueActivationReplacesScheduleAndDeactivateCancelsIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstDueAt = now.addingTimeInterval(60)
        let secondDueAt = now.addingTimeInterval(120)
        for (id, dueAt) in [("first", firstDueAt), ("second", secondDueAt)] {
            let card = makeCard(id: id, expression: id, dueAt: dueAt)
            let record = LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
            record.isInActiveSession = false
            container.mainContext.insert(record)
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            dueActivationScheduler: scheduler
        )

        XCTAssertEqual(scheduler.deadline, firstDueAt)
        XCTAssertTrue(scheduler.fire())
        XCTAssertEqual(store.cards.map(\.id), ["first"])
        XCTAssertEqual(scheduler.deadline, secondDueAt)
        XCTAssertEqual(scheduler.scheduleCount, 2)

        let cancelCount = scheduler.cancelCount
        store.deactivate()

        XCTAssertNil(scheduler.deadline)
        XCTAssertGreaterThan(scheduler.cancelCount, cancelCount)
        XCTAssertFalse(scheduler.fire())
        XCTAssertTrue(store.cards.isEmpty)
        await Task.yield()
    }

    @MainActor
    func testLessonPresentationSuspendsAndRestoresDueActivationSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dueAt = now.addingTimeInterval(60)
        let card = makeCard(id: "lesson-transition", expression: "授業", dueAt: dueAt)
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            dueActivationScheduler: scheduler
        )

        XCTAssertEqual(scheduler.deadline, dueAt)
        store.beginLessonSessionPresentation()
        XCTAssertNil(scheduler.deadline)
        XCTAssertFalse(scheduler.fire())

        store.endLessonSessionPresentation()
        XCTAssertEqual(scheduler.deadline, dueAt)
        XCTAssertTrue(scheduler.fire())
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        store.deactivate()
        await Task.yield()
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
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = makeSessionStore(
            in: container,
            client: client,
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
        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertEqual(store.sessionFailureCount, 1)

        store.activateOfflineDueCards(at: againDueAt.addingTimeInterval(-1))
        XCTAssertTrue(store.cards.isEmpty)

        store.activateOfflineDueCards(at: againDueAt)
        let firstRetryCard = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(firstRetryCard.state.queueState, "relearning")
        XCTAssertNotNil(firstRetryCard.state.failedAt)

        await store.recordReview(
            card: firstRetryCard,
            rating: .again,
            duration: nil,
            reviewedAt: againDueAt
        )

        XCTAssertEqual(store.sessionFailureCount, 1)
        let secondRetryDueAt = try XCTUnwrap(store.libraryCards.first?.state.dueAt)
        store.activateOfflineDueCards(at: secondRetryDueAt)
        let secondRetryCard = try XCTUnwrap(store.cards.first)

        await store.recordReview(
            card: secondRetryCard,
            rating: .good,
            duration: nil,
            reviewedAt: secondRetryDueAt
        )

        assertClearedFailureState(in: store)

        let relaunched = makeSessionStore(
            in: container,
            client: client,
            mediaCache: mediaCache
        )
        assertClearedFailureState(in: relaunched)

        let goodDueAt = try XCTUnwrap(relaunched.libraryCards.first?.state.dueAt)
        XCTAssertEqual(goodDueAt, secondRetryDueAt.addingTimeInterval(24 * 60 * 60))
        relaunched.activateOfflineDueCards(at: goodDueAt)
        assertActiveReviewCard(in: relaunched, expectedID: card.id)
    }

    @MainActor
    func testFirstTimeOfflineFailureSurvivesRelaunchAndStaleServerRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000011", expression: "再学習")
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
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = makeSessionStore(
            in: container,
            client: client,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .again, duration: nil)

        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertTrue(store.cards.isEmpty)

        let relaunched = makeSessionStore(
            in: container,
            client: client,
            mediaCache: mediaCache
        )
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)
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
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)
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
                userID: 1,
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
        let store = makeSessionStore(in: container, client: client)

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), [availableCard.id])
        XCTAssertEqual(store.overview?.dueCount, 2)
    }

    @MainActor
    func testOlderReviewSessionResponseCannotOverwriteNewerRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let olderCard = makeCard(id: "older-session-card", expression: "古いセッション")
        let newerCard = makeCard(id: "newer-session-card", expression: "新しいセッション")
        let olderData = try sessionResponseData(cards: [olderCard])
        let newerData = try sessionResponseData(cards: [newerCard])
        let store = makeOverlappingSessionStore(
            in: container,
            responses: OverlappingSessionResponses(
                firstReview: olderData,
                secondReview: newerData,
                lesson: newerData
            )
        )

        let olderRefresh = Task { try await store.refreshSession() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingFirstReview)
        try await store.refreshSession()
        XCTAssertEqual(store.cards.map(\.id), [newerCard.id])
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        _ = try await olderRefresh.value

        XCTAssertEqual(store.cards.map(\.id), [newerCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [newerCard.id])
    }

    @MainActor
    func testReviewSessionPreservesServerOrder() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let serverCards = [
            makeCard(id: "server-new-first", expression: "New", queueState: "new"),
            makeCard(
                id: "server-review-later",
                expression: "Later",
                queueState: "review",
                dueAt: now.addingTimeInterval(60)
            ),
            makeCard(
                id: "server-review-earlier",
                expression: "Earlier",
                queueState: "review",
                dueAt: now
            ),
        ]
        let data = try sessionResponseData(cards: serverCards)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/session/start")
            return Self.response(data: data)
        }
        let store = makeSessionStore(in: container, client: client)

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), serverCards.map(\.id))
    }

    @MainActor
    func testReviewResponseStartedBeforeLessonCannotReplacePresentedLesson() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "stale-review-card", expression: "古い復習")
        let lessonCard = makeCard(
            id: "current-lesson-card",
            expression: "現在のレッスン",
            queueState: "new"
        )
        let reviewData = try sessionResponseData(cards: [reviewCard])
        let lessonData = try sessionResponseData(cards: [lessonCard], lessonBatchSize: 3)
        let store = makeOverlappingSessionStore(
            in: container,
            responses: OverlappingSessionResponses(
                firstReview: reviewData,
                secondReview: reviewData,
                lesson: lessonData
            )
        )

        let reviewRefresh = Task { try await store.refreshSession() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingFirstReview)
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        _ = try await reviewRefresh.value

        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [lessonCard.id])
    }

    @MainActor
    func testRapidLessonOpenAndCloseReportsDiscardedSessionLoads() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let existingCard = makeCard(id: "existing-card", expression: "既存")
        container.mainContext.insert(
            LocalCardRecord(
                card: existingCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(existingCard)
            )
        )
        try container.mainContext.save()
        let reviewData = try sessionResponseData(
            cards: [makeCard(id: "discarded-review", expression: "破棄する復習")]
        )
        let lessonData = try sessionResponseData(
            cards: [makeCard(id: "discarded-lesson", expression: "破棄するレッスン")],
            lessonBatchSize: 3
        )
        let store = makeOverlappingSessionStore(
            in: container,
            responses: OverlappingSessionResponses(
                firstReview: reviewData,
                secondReview: reviewData,
                lesson: lessonData,
                holdLesson: true
            )
        )

        let reviewRefresh = Task {
            try await store.refreshSessionPreservingActiveLessons()
        }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        store.beginLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)
        let lessonRefresh = Task { try await store.refreshLessons() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingLesson }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingLesson)
        store.endLessonSessionPresentation()
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        OverlappingStudySessionURLProtocol.releaseLesson()

        let reviewApplied = try await reviewRefresh.value
        let lessonApplied = try await lessonRefresh.value
        XCTAssertFalse(reviewApplied)
        XCTAssertFalse(lessonApplied)
        XCTAssertEqual(store.cards.map(\.id), [existingCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [existingCard.id])
    }

    @MainActor
    private func makeSessionStore(
        in container: ModelContainer,
        client: APIClient,
        storageMode: StorageMode = .persistent
    ) -> StudyStore {
        makeSessionStore(
            in: container,
            client: client,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            storageMode: storageMode
        )
    }

    @MainActor
    private func makeSessionStore(
        in container: ModelContainer,
        client: APIClient,
        mediaCache: MediaCache,
        storageMode: StorageMode = .persistent
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache,
            storageMode: storageMode
        )
    }

    @MainActor
    private func assertClearedFailureState(in store: StudyStore) {
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertEqual(store.sessionFailureCount, 0)
    }

    @MainActor
    private func assertActiveReviewCard(in store: StudyStore, expectedID: String) {
        XCTAssertEqual(store.cards.map(\.id), [expectedID])
        XCTAssertEqual(store.cards.first?.state.queueState, "review")
        XCTAssertNil(store.cards.first?.state.failedAt)
    }

    @MainActor
    private func makeOverlappingSessionStore(
        in container: ModelContainer,
        responses: OverlappingSessionResponses
    ) -> StudyStore {
        OverlappingStudySessionURLProtocol.configure(
            firstReview: responses.firstReview,
            secondReview: responses.secondReview,
            lesson: responses.lesson,
            holdLesson: responses.holdLesson
        )
        let client = makeClient(protocolClass: OverlappingStudySessionURLProtocol.self)
        return makeSessionStore(in: container, client: client)
    }

    @MainActor
    private func pendingCardCreateRequest(
        in container: ModelContainer
    ) throws -> CreateStudyCardRequest {
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardCreate" })
        )
        return try StorageCodec.decoder.decode(
            CreateStudyCardRequest.self,
            from: mutation.payload
        )
    }

    @MainActor
    private func assertOfflineCardCreation(
        _ testCase: OfflineCardCreationCase
    ) async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = makeSessionStore(in: container, client: client)
        var draft = StudyCardDraft(cardType: testCase.cardType)
        draft.cueText = testCase.cueText
        draft.cueMeaning = testCase.cueMeaning
        draft.answerExpression = testCase.answerExpression
        draft.answerReading = testCase.answerReading
        draft.answerMeaning = testCase.answerMeaning

        try await store.createCard(draft)

        let card = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(card.cardType, testCase.cardType.rawValue)
        XCTAssertEqual(card.prompt[testCase.promptKey]?.stringValue, testCase.promptValue)
        XCTAssertEqual(card.answer[testCase.answerKey]?.stringValue, testCase.answerValue)
        let request = try pendingCardCreateRequest(in: container)
        XCTAssertEqual(request.cardType, testCase.cardType.rawValue)
        XCTAssertEqual(request.prompt, card.prompt)
        XCTAssertEqual(request.answer, card.answer)
    }

    private static func response(
        for request: URLRequest,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}

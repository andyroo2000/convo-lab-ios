import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    private struct AccountCardSpec {
        let id: String
        let expression: String
    }

    @MainActor
    func testStaleStudySettingsResponseCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":12}"#.utf8)
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

        let refresh = Task { await store.refreshStudySettings() }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        store.activate(userID: 1)
        gate.release()
        await refresh.value

        XCTAssertNil(store.studySettings)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testStaleStudySettingsUpdateCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            gate.markStarted()
            gate.waitForRelease()
            return Self.response(data: Data(
                #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
            ))
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

        let update = Task {
            await store.updateStudySettings(
                newCardsPerDay: 24,
                lessonBatchSize: 8,
                reviewTimeBudgetMinutes: 150
            )
        }
        await waitUntil { gate.hasStarted }

        store.activate(userID: 2)
        store.activate(userID: 1)
        gate.release()
        let saved = await update.value

        XCTAssertFalse(saved)
        XCTAssertNil(store.studySettings)
        XCTAssertNil(store.studySettingsErrorMessage)
        XCTAssertFalse(store.isUpdatingStudySettings)
    }

    @MainActor
    func testStaleNewCardQueueResponseCannotPopulateNewAccount() async throws {
        let cardID = "01J00000000000000000000001"
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/new-queue")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "items": [{
                        "id": "\(cardID)",
                        "noteId": "\(cardID)",
                        "cardType": "recognition",
                        "displayText": "犬",
                        "meaning": "dog",
                        "queuePosition": 1,
                        "createdAt": "2026-07-25T12:00:00.000Z",
                        "updatedAt": "2026-07-25T12:00:00.000Z"
                      }],
                      "total": 1,
                      "limit": 100,
                      "nextCursor": null
                    }
                    """.utf8
                )
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

        let refresh = Task { try await store.refreshNewCardQueue() }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        gate.release()
        try await refresh.value

        XCTAssertTrue(store.newCardQueue.isEmpty)
        XCTAssertEqual(store.newCardQueueTotal, 0)
    }

    @MainActor
    func testStaleCheckpointResponseCannotReplaceNewAccountsCards() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (_, userTwoCard) = try persistAccountCards(
            in: container,
            userOne: AccountCardSpec(
                id: "01J00000000000000000000A1",
                expression: "前の利用者"
            ),
            userTwo: AccountCardSpec(
                id: "01J00000000000000000000A2",
                expression: "現在の利用者"
            )
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            guard request.url?.path == "/api/sync/feed" else {
                throw URLError(.badServerResponse)
            }
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Checkpoint expired"}"#.utf8)
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

        let synchronization = Task { await store.synchronize() }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await synchronization.value

        assertActiveCards(in: store, equal: userTwoCard)
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testStaleCardMutationDrainCannotReloadPreviousAccountsCards() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (userOneCard, userTwoCard) = try persistAccountCards(
            in: container,
            userOne: AccountCardSpec(
                id: "01J00000000000000000000B1",
                expression: "前の利用者"
            ),
            userTwo: AccountCardSpec(
                id: "01J00000000000000000000B2",
                expression: "現在の利用者"
            )
        )

        let gate = LockedRequestGate()
        let userOneCardID = userOneCard.id
        let serverCardData = try StorageCodec.encoder.encode(userOneCard)
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(userOneCardID)")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                serverCardData
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

        let update = Task {
            try await store.updateCard(
                userOneCard,
                prompt: "更新中",
                reading: "こうしんちゅう",
                answer: "updating"
            )
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        assertActiveCards(in: store, equal: userTwoCard)
        gate.release()
        try await update.value

        assertActiveCards(in: store, equal: userTwoCard)
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testCancelledReviewFromPreviousAccountCannotFailCurrentAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (userOneCard, userTwoCard) = try persistAccountCards(
            in: container,
            userOne: AccountCardSpec(
                id: "01J00000000000000000000B3",
                expression: "前の利用者の復習"
            ),
            userTwo: AccountCardSpec(
                id: "01J00000000000000000000B4",
                expression: "現在の利用者の復習"
            )
        )

        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            gate.markStarted()
            gate.waitForRelease()
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

        let review = Task {
            await store.recordReview(card: userOneCard, rating: .good, duration: nil)
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        _ = await review.value

        assertActiveCards(in: store, equal: userTwoCard)
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testCancelledReviewCannotFailReactivatedSameAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000B5",
            expression: "再認証前の復習"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()

        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            gate.markStarted()
            gate.waitForRelease()
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

        let review = Task {
            await store.recordReview(card: card, rating: .good, duration: nil)
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.deactivate()
        store.activate(userID: 1)
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        _ = await review.value

        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testStaleSynchronizationCannotFailReactivatedSameAccount() async throws {
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
        let gate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
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
            case "/api/study/offline-reserve":
                gate.markStarted()
                gate.waitForRelease()
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.badURL)
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

        let synchronization = Task { await store.synchronize() }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.deactivate()
        store.activate(userID: 1)
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        await synchronization.value

        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testAccountSwitchCannotAdvanceCheckpointPastSkippedCardChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000C1",
            expression: "未適用"
        )
        let serverCardID = serverCard.id
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let serverCardObject = try JSONSerialization.jsonObject(with: serverCardData)
        let serverCardBatchData = try JSONSerialization.data(
            withJSONObject: ["cards": [serverCardObject]]
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/sync/feed":
                return Self.response(data: Data(
                    """
                    {"data":[{"checkpoint":9,"resource_id":"\(serverCardID)","operation":"update"}],
                    "meta":{"next_checkpoint":9,"has_more":false}}
                    """.utf8
                ))
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: serverCardBatchData)
            default:
                throw URLError(.badServerResponse)
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

        let synchronization = Task { await store.synchronize() }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await synchronization.value

        let states = try container.mainContext.fetch(FetchDescriptor<LocalSyncState>())
        XCTAssertEqual(states.first(where: { $0.userID == 1 })?.cardCheckpoint, 0)
        XCTAssertFalse(try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        ).contains(where: { $0.userID == 1 && $0.id == serverCardID }))
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    private func persistAccountCards(
        in container: ModelContainer,
        userOne: AccountCardSpec,
        userTwo: AccountCardSpec
    ) throws -> (userOne: StudyCard, userTwo: StudyCard) {
        let userOneCard = makeCard(id: userOne.id, expression: userOne.expression)
        let userTwoCard = makeCard(id: userTwo.id, expression: userTwo.expression)
        container.mainContext.insert(LocalCardRecord(
            card: userOneCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(userOneCard)
        ))
        container.mainContext.insert(LocalCardRecord(
            card: userTwoCard,
            userID: 2,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(userTwoCard)
        ))
        try container.mainContext.save()
        return (userOneCard, userTwoCard)
    }

    @MainActor
    private func assertActiveCards(in store: StudyStore, equal card: StudyCard) {
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
    }
}

import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testUndoReviewRestoresFrozenSessionProgress() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001T",
            expression: "進捗"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 2
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": object])
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
            throw URLError(.notConnectedToInternet)
        }
        let store = makeUndoStore(in: container, client: client)
        try await store.refreshSession()

        XCTAssertEqual(store.sessionCounts.failedDue, 2)
        XCTAssertEqual(store.sessionFailureCount, 0)

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .again,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertEqual(store.sessionProgress, 1)
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.refreshSession()
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.sessionFailureCount, 0)
        XCTAssertEqual(store.cards.map(\.id), [card.id])

        await store.recordReview(card: card, rating: .again, duration: nil)
        XCTAssertEqual(store.sessionFailureCount, 1)
        let secondCard = makeCard(
            id: "01J0000000000000000000001V",
            expression: "失敗"
        )
        await store.recordReview(card: secondCard, rating: .again, duration: nil)
        XCTAssertEqual(store.sessionFailureCount, 2)
        store.beginSessionFailureTracking()
        XCTAssertEqual(store.sessionFailureCount, 0)
    }

    @MainActor
    func testUndoReviewRemovesPendingOfflineEventAndRestoresCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001U",
            expression: "戻す",
            masteryLevel: "guru"
        )
        let localRecord = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 1_000)
        container.mainContext.insert(localRecord)
        try container.mainContext.save()
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = makeUndoStore(in: container, client: client)

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: .milliseconds(500)
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(requestCount.current, 1)
        XCTAssertEqual(store.pendingOfflineReviewCount, 1)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(requestCount.current, 1)
        XCTAssertEqual(store.pendingOfflineReviewCount, 0)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertTrue(record.isInActiveSession)
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state, card.state)
        XCTAssertEqual(persisted.masteryLevel, "guru")
        XCTAssertEqual(store.cards.first?.masteryLevel, "guru")
    }

    @MainActor
    func testServerUndoLeanResponsePreservesProgressionLock() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000LU",
            expression: "取り消す",
            variantGroupID: "family-1",
            variantStatus: "locked"
        )
        try persistUndoCard(card, in: container)
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        var leanCard = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: StorageCodec.encoder.encode(card)
            ) as? [String: Any]
        )
        leanCard.removeValue(forKey: "variantGroupId")
        leanCard.removeValue(forKey: "variantStatus")
        let responseData = try JSONSerialization.data(withJSONObject: [
            "reviewLogId": "server-event",
            "card": leanCard,
            "overview": try JSONSerialization.jsonObject(
                with: StorageCodec.encoder.encode(overview)
            ),
        ])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/reviews/undo")
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
        let store = makeUndoStore(in: container, client: client)

        try await store.undoReview(eventID: "server-event", cardBefore: card)

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.variantGroupId, "family-1")
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertEqual(store.cards.first?.variantStatus, "locked")
    }

    @MainActor
    func testUndoSyncedReviewUsesCanonicalUndoResponse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001V",
            expression: "取り消す"
        )
        try persistUndoCard(card, in: container)
        let overview = Self.readyUndoOverview()
        let paths = LockedRequestPaths()
        let undoEventIDs = LockedRequestPaths()
        let cardJSON = try Self.encodedJSONString(card)
        let overviewJSON = try Self.encodedJSONString(overview)
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/study/settings" {
                return try Self.httpResponse(
                    for: request,
                    data: Data(
                        #"{"newCardsPerDay":10,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            }
            if path == "/api/card-review-events/batch" {
                return try Self.httpResponse(for: request, data: Data(), statusCode: 201)
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            XCTAssertNil(body?["currentOverview"])
            XCTAssertNil(body?["current_overview"])
            undoEventIDs.append(eventID)
            return try Self.httpResponse(
                for: request,
                data: Self.undoResponseData(
                    eventID: eventID,
                    cardJSON: cardJSON,
                    overviewJSON: overviewJSON
                )
            )
        }
        let store = makeUndoStore(in: container, client: client)

        await store.refreshStudySettings()

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .easy,
            duration: .seconds(1)
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        try assertNoPendingReviews(in: container)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/settings",
                "/api/card-review-events/batch",
                "/api/study/reviews/undo",
            ]
        )
        XCTAssertEqual(undoEventIDs.values, [eventID.lowercased()])
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 1)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
    }

    @MainActor
    func testUndoWaitsForInFlightReviewUploadBeforeCallingServerUndo() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001X",
            expression: "競合を避ける"
        )
        try persistUndoCard(card, in: container)

        let cardJSON = try Self.encodedJSONString(card)
        let overviewJSON = try Self.encodedJSONString(Self.undoOverview())
        let gate = LockedRequestGate()
        let paths = LockedRequestPaths()
        let uploadedEventIDs = LockedRequestPaths()
        let undoEventIDs = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/card-review-events/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
                let eventID = try XCTUnwrap(events.first?["id"] as? String)
                uploadedEventIDs.append(eventID)
                gate.markStarted()
                gate.waitForRelease()
                return try Self.httpResponse(for: request, data: Data(), statusCode: 201)
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            undoEventIDs.append(eventID)
            return try Self.httpResponse(
                for: request,
                data: Self.undoResponseData(
                    eventID: eventID,
                    cardJSON: cardJSON,
                    overviewJSON: overviewJSON
                )
            )
        }
        let store = makeUndoStore(in: container, client: client)

        let reviewTask = Task {
            await store.recordReview(
                card: card,
                rating: .good,
                duration: .milliseconds(500)
            )
        }
        await waitUntil { gate.hasStarted }
        let eventID = try XCTUnwrap(uploadedEventIDs.values.first)
        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: card)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(paths.values, ["/api/card-review-events/batch"])

        gate.release()
        let recordedEventID = await reviewTask.value
        try await undoTask.value

        XCTAssertEqual(recordedEventID, eventID)
        XCTAssertEqual(
            paths.values,
            ["/api/card-review-events/batch", "/api/study/reviews/undo"]
        )
        XCTAssertEqual(undoEventIDs.values, [eventID.lowercased()])
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        try assertNoPendingReviews(in: container)
    }

    @MainActor
    func testPendingDeleteDuringServerUndoDoesNotApplyRestoredOverview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002A",
            expression: "削除競合"
        )
        try persistUndoCard(card, in: container)
        let cardJSON = try Self.encodedJSONString(card)
        let overviewJSON = try Self.encodedJSONString(Self.undoOverview())
        let gate = LockedRequestGate()
        let client = makeClient { request in
            guard request.url?.path == "/api/study/reviews/undo" else {
                throw URLError(.notConnectedToInternet)
            }
            gate.markStarted()
            gate.waitForRelease()
            return try Self.httpResponse(
                for: request,
                data: Self.undoResponseData(
                    eventID: "01j0000000000000000000002b",
                    cardJSON: cardJSON,
                    overviewJSON: overviewJSON
                )
            )
        }
        let store = makeUndoStore(in: container, client: client)

        let undoTask = Task {
            try await store.undoReview(
                eventID: "01J0000000000000000000002B",
                cardBefore: card
            )
        }
        await waitUntil { gate.hasStarted }
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: card.id,
                payload: Data()
            )
        )
        let localRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        )
        for record in localRecords {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
        gate.release()

        do {
            try await undoTask.value
            XCTFail("Expected the pending delete to reject restoration.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This card was deleted and cannot be restored."
            )
        }

        XCTAssertNil(store.overview)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<LocalCardRecord>()
            ).isEmpty
        )
    }

    @MainActor
    func testUndoDoesNotResurrectCardWithPendingDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "削除済み"
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: "SERVER-CARD-ID",
                payload: Data()
            )
        )
        try container.mainContext.save()
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.badServerResponse)
        }
        let store = makeUndoStore(in: container, client: client)

        do {
            try await store.undoReview(
                eventID: "01J0000000000000000000001Z",
                cardBefore: card
            )
            XCTFail("Expected undo to reject a pending card deletion.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This card was deleted and cannot be restored."
            )
        }

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<LocalCardRecord>()
            ).isEmpty
        )
    }

    @MainActor
    func testUndoReviewReusesCanonicalRecordAndPreservesPendingEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let originalID = "01J0000000000000000000001W"
        let canonicalID = originalID.lowercased()
        let locallyEditedCard = makeCard(
            id: originalID,
            expression: "Local pending edit",
            queueState: "review",
            masteryLevel: "guru"
        )
        let dirtyAt = Date(timeIntervalSince1970: 1_000)
        let record = LocalCardRecord(
            card: locallyEditedCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(locallyEditedCard)
        )
        record.id = canonicalID
        record.locallyUpdatedAt = dirtyAt
        container.mainContext.insert(record)
        try container.mainContext.save()

        let serverCard = makeCard(
            id: originalID,
            expression: "Stale server expression",
            queueState: "learning",
            dueAt: Date(timeIntervalSince1970: 2_000),
            masteryLevel: "apprentice"
        )
        let cardJSON = try cardJSONWithPresentation(
            serverCard,
            frontHeading: "Stale projected server expression"
        )
        let overviewJSON = try Self.encodedJSONString(Self.undoOverview())
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/reviews/undo")
            return try Self.httpResponse(
                for: request,
                data: Self.undoResponseData(
                    eventID: "review-event-id",
                    cardJSON: cardJSON,
                    overviewJSON: overviewJSON
                )
            )
        }
        let store = makeUndoStore(in: container, client: client)

        try await store.undoReview(
            eventID: "review-event-id",
            cardBefore: locallyEditedCard
        )

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        )
        XCTAssertEqual(records.count, 1)
        let restoredRecord = try XCTUnwrap(records.first)
        XCTAssertEqual(restoredRecord.id, canonicalID)
        XCTAssertEqual(restoredRecord.locallyUpdatedAt, dirtyAt)
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.id, canonicalID)
        XCTAssertEqual(restoredCard.promptText, "Local pending edit")
        XCTAssertNil(restoredCard.serverPresentation)
        XCTAssertEqual(restoredCard.masteryLevel, "apprentice")
        XCTAssertEqual(restoredCard.state, serverCard.state)
        XCTAssertEqual(store.cards.first, restoredCard)
    }

    @MainActor
    func testUndoReviewKeepsServerPresentationWhenDirtyLocalPayloadIsCorrupt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let cardID = "01J0000000000000000000001X"
        let serverCard = makeCard(
            id: cardID,
            expression: "Server raw expression",
            queueState: "review"
        )
        let record = LocalCardRecord(
            card: serverCard,
            userID: 1,
            queueIndex: 0,
            payload: Data("corrupt-local-card".utf8)
        )
        record.locallyUpdatedAt = Date(timeIntervalSince1970: 1_000)
        container.mainContext.insert(record)
        try container.mainContext.save()

        let projectedCardJSON = try cardJSONWithPresentation(
            serverCard,
            frontHeading: "Projected front"
        )
        let overviewJSON = try Self.encodedJSONString(Self.undoOverview())
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/reviews/undo")
            return try Self.httpResponse(
                for: request,
                data: Self.undoResponseData(
                    eventID: "review-event-id",
                    cardJSON: projectedCardJSON,
                    overviewJSON: overviewJSON
                )
            )
        }
        let store = makeUndoStore(in: container, client: client)

        try await store.undoReview(eventID: "review-event-id", cardBefore: serverCard)

        let restoredRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.serverPresentation?.version, 1)
        XCTAssertEqual(restoredCard.presentation.front.heading, "Projected front")
        XCTAssertEqual(store.cards.first?.serverPresentation, restoredCard.serverPresentation)
    }

    @MainActor
    private func makeUndoStore(
        in container: ModelContainer,
        client: APIClient
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func persistUndoCard(
        _ card: StudyCard,
        in container: ModelContainer
    ) throws {
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
    }

    @MainActor
    private func assertNoPendingReviews(in container: ModelContainer) throws {
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
    }

    @MainActor
    private static func undoOverview() -> StudyOverview {
        StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
    }

    @MainActor
    private static func readyUndoOverview() -> StudyOverview {
        StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0,
            learningReadiness: StudyLearningReadiness(
                recommendation: "ready",
                readinessLevel: "ready",
                sampleSize: 40,
                sufficientData: true,
                recentRecall: 0.95,
                targetRecall: 0.9,
                dueBacklog: 0,
                apprenticeCount: 0,
                projectedSevenDayReviews: 28,
                timedReviewSampleSize: 40,
                medianReviewDurationSeconds: 900,
                projectedDailyReviewMinutes: 60,
                reviewTimeBudgetMinutes: nil,
                reviewTimeHeadroomMinutes: nil,
                suggestedBatchSize: 5
            )
        )
    }

    @MainActor
    private static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(value),
                encoding: .utf8
            )
        )
    }

    private static func undoResponseData(
        eventID: String,
        cardJSON: String,
        overviewJSON: String
    ) -> Data {
        Data(
            """
            {
              "reviewLogId": "\(eventID)",
              "card": \(cardJSON),
              "overview": \(overviewJSON)
            }
            """.utf8
        )
    }

    private static func httpResponse(
        for request: URLRequest,
        data: Data,
        statusCode: Int = 200
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    @MainActor
    private func cardJSONWithPresentation(
        _ card: StudyCard,
        frontHeading: String
    ) throws -> String {
        var cardObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: StorageCodec.encoder.encode(card)
            ) as? [String: Any]
        )
        cardObject["presentation"] = [
            "version": 1,
            "front": [
                "mode": "text",
                "text": frontHeading,
                "ruby": NSNull(),
                "hint": NSNull(),
                "media": ["audio": NSNull(), "image": NSNull()],
                "autoplayAudio": false,
            ],
            "answer": [
                "heading": "Projected answer",
                "ruby": NSNull(),
                "restored": NSNull(),
                "meaning": NSNull(),
                "sentences": [
                    "japanese": ["text": NSNull(), "ruby": NSNull()],
                    "english": ["text": NSNull(), "ruby": NSNull()],
                ],
                "notes": [],
                "media": ["image": NSNull()],
                "audio": NSNull(),
                "pitchAccent": NSNull(),
            ],
        ]
        return try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: cardObject),
                encoding: .utf8
            )
        )
    }
}

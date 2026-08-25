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
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
    func testUndoSyncedReviewUsesCanonicalUndoResponse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001V",
            expression: "取り消す"
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
        let overview = StudyOverview(
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
        let paths = LockedRequestPaths()
        let undoEventIDs = LockedRequestPaths()
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/study/settings" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":10,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            }
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            undoEventIDs.append(eventID)
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
                      "reviewLogId": "\(eventID)",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.refreshStudySettings()

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .easy,
            duration: .seconds(1)
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )

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
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
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
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            undoEventIDs.append(eventID)
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
                      "reviewLogId": "\(eventID)",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
    }

    @MainActor
    func testPendingDeleteDuringServerUndoDoesNotApplyRestoredOverview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002A",
            expression: "削除競合"
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
        let responseOverview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(responseOverview),
                encoding: .utf8
            )
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            guard request.url?.path == "/api/study/reviews/undo" else {
                throw URLError(.notConnectedToInternet)
            }
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
                      "reviewLogId": "01j0000000000000000000002b",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(serverCard),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/reviews/undo")
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
                      "reviewLogId": "review-event-id",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
        XCTAssertEqual(restoredCard.masteryLevel, "apprentice")
        XCTAssertEqual(restoredCard.state, serverCard.state)
        XCTAssertEqual(store.cards.first, restoredCard)
    }
}

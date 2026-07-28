import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyActivitySessionTests: XCTestCase {
    func testActivitiesMapToOnePrimaryCategory() {
        XCTAssertEqual(StudyActivityKind.cardReview.category, .review)
        XCTAssertEqual(StudyActivityKind.dailyAudio.category, .review)
        XCTAssertEqual(StudyActivityKind.cardCreation.category, .create)
        XCTAssertEqual(StudyActivityKind.tv.category, .immerse)
        XCTAssertEqual(StudyActivityKind.podcast.category, .immerse)
        XCTAssertEqual(StudyActivityKind.reading.category, .immerse)
        XCTAssertEqual(StudyActivityKind.conversation.category, .immerse)
        XCTAssertEqual(StudyActivityKind.other.category, .immerse)
    }

    func testBatchEncodesRetrySafeClientIdentityAndOutputMetrics() throws {
        let session = StudyActivitySession(
            id: nil,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000001",
            category: .create,
            activity: .cardCreation,
            source: .manual,
            name: "Episode cards",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationMs: 3_600_000,
            audioPlaybackMs: nil,
            cardsCreated: 12
        )

        let data = try JSONEncoder().encode(StudyActivityBatchRequest(sessions: [session]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap((body["sessions"] as? [[String: Any]])?.first)

        XCTAssertEqual(
            encoded["clientSessionId"] as? String,
            "018f22d2-6d38-7000-8000-000000000001"
        )
        XCTAssertEqual(encoded["category"] as? String, "create")
        XCTAssertEqual(encoded["activity"] as? String, "card_creation")
        XCTAssertEqual(encoded["cardsCreated"] as? Int, 12)
    }

    func testDeactivateFinishesAndFlushesActiveSessionBeforeClearingAccount() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/activity-sessions/batch")
            let body = try requestBody(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let postedSession = try XCTUnwrap(
                (json["sessions"] as? [[String: Any]])?.first
            )
            XCTAssertEqual(postedSession["activity"] as? String, "card_review")
            let responseBody = try JSONSerialization.data(withJSONObject: [postedSession])
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseBody
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        let startedAt = Date.now.addingTimeInterval(-60)
        store.activate(userID: 42)
        store.start(activity: .cardReview, source: .automatic, at: startedAt)

        await store.deactivate()

        XCTAssertNil(store.active)
        XCTAssertTrue(store.sessions.isEmpty)
        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(try XCTUnwrap(records.first).syncPending)
        XCTAssertNotNil(records.first?.endedAt)
    }

    func testForegroundSynchronizationDoesNotRecoverALiveAutomaticSession() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/activity-sessions")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("[]".utf8)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        let startedAt = Date.now.addingTimeInterval(-10 * 60)
        store.activate(userID: 42)
        store.start(
            activity: .dailyAudio,
            source: .automatic,
            name: "Daily drill",
            at: startedAt
        )

        await store.synchronize()

        XCTAssertEqual(store.active?.activity, .dailyAudio)
        XCTAssertEqual(store.active?.startedAt, startedAt)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertNil(record.endedAt)
        XCTAssertFalse(record.syncPending)
    }

    func testSynchronizationDeduplicatesRepeatedRemoteClientSessionIDs() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let remoteSession: [String: Any] = [
            "id": "remote-session-1",
            "clientSessionId": "018f22d2-6d38-7000-8000-000000000008",
            "category": "immerse",
            "activity": "tv",
            "source": "manual",
            "name": "Drama",
            "startedAt": "2026-07-28T20:00:00Z",
            "endedAt": "2026-07-28T20:30:00Z",
            "durationMs": 1_800_000,
        ]
        let responseData = try JSONSerialization.data(
            withJSONObject: [remoteSession, remoteSession]
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/activity-sessions")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.synchronize()

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions.first?.clientSessionId,
            "018f22d2-6d38-7000-8000-000000000008"
        )
    }

    func testColdLaunchCapsAnAbandonedAutomaticSessionAtFiveMinutes() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let startedAt = Date.now.addingTimeInterval(-10 * 60)
        let abandoned = StudyTimeStore.ActiveSession(
            clientSessionID: "018f22d2-6d38-7000-8000-000000000004",
            category: .review,
            activity: .dailyAudio,
            source: .automatic,
            name: "Abandoned drill",
            startedAt: startedAt,
            cardsCreated: 0
        )
        container.mainContext.insert(
            LocalStudyActivitySession(active: abandoned, userID: 42)
        )
        try container.mainContext.save()
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: sessions)
                )
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("[]".utf8)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)

        store.activate(userID: 42)
        await store.synchronize()

        XCTAssertNil(store.active)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(record.durationMs, 300_000)
        let endedAt = try XCTUnwrap(record.endedAt)
        XCTAssertEqual(
            endedAt.timeIntervalSince1970,
            startedAt.addingTimeInterval(5 * 60).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertFalse(record.syncPending)
    }

    func testAutomaticTeardownCannotStopAManualTimerWithTheSameActivity() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let body = try requestBody(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: sessions)
            )
        }
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext
        )
        store.activate(userID: 42)
        store.start(activity: .cardCreation, source: .manual, name: "Deck work")

        store.start(activity: .cardCreation, source: .automatic)
        store.stop(activity: .cardCreation, source: .automatic)

        XCTAssertEqual(store.active?.source, .manual)
        XCTAssertEqual(store.active?.name, "Deck work")
        await store.deactivate()
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}

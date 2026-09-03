import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
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

    func testLeavingForegroundStopsAutomaticTrackingAtTransitionTime() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let suspendedAt = startedAt.addingTimeInterval(90)
        store.activate(userID: 42)
        store.start(
            activity: .cardReview,
            source: .automatic,
            name: "Lessons",
            at: startedAt
        )

        store.stopForegroundAutomaticTracking(at: suspendedAt)

        XCTAssertNil(store.active)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(record.endedAt, suspendedAt)
        XCTAssertEqual(record.durationMs, 90_000)
        XCTAssertTrue(record.syncPending)

        await store.deactivate(at: suspendedAt)
    }

    func testForegroundSynchronizationDoesNotRecoverALiveAutomaticSession() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
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

    func testSuccessfulSynchronizationDoesNotClearBlockedStorageWriteWarning() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
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
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext,
            storageMode: .temporary
        )
        store.activate(userID: 42)

        store.start(activity: .reading, source: .manual)
        await store.synchronize()

        XCTAssertNil(store.active)
        XCTAssertNil(store.syncErrorMessage)
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            StorageWriteUnavailableError(domain: .studyTime).localizedDescription
        )
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
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
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

    func testSynchronizationDoesNotDeleteALocalSessionOmittedByRemoteRefresh() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let localSession = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: localSession, userID: 42)
        )
        try container.mainContext.save()
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
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
        store.activate(userID: 42)

        await store.synchronize()

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.clientSessionID, localSession.clientSessionId)
        XCTAssertEqual(store.sessions, [localSession])
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
}

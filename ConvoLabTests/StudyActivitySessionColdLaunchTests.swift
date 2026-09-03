import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testColdLaunchCapsAnAbandonedAutomaticSessionAtFiveMinutes() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let startedAt = Date.now.addingTimeInterval(-10 * 60)
        let abandoned = StudyTimeStore.ActiveSession(
            clientSessionID: "018f22d2-6d38-7000-8000-000000000004",
            category: .listen,
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
                return try Self.jsonResponse(
                    for: request,
                    body: Self.batchSessions(from: request)
                )
            }
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
            if request.url?.path == "/api/study/activity-sessions" {
                let recovered: [[String: Any]] = [[
                    "id": "recovered-session",
                    "clientSessionId": "018f22d2-6d38-7000-8000-000000000004",
                    "category": "listen",
                    "activity": "daily_audio",
                    "source": "automatic",
                    "name": "Abandoned drill",
                    "startedAt": startedAt.ISO8601Format(),
                    "endedAt": startedAt.addingTimeInterval(5 * 60).ISO8601Format(),
                    "durationMs": 300_000,
                    "audioPlaybackMs": 300_000,
                ]]
                return try Self.jsonResponse(for: request, body: recovered)
            }
            return try Self.jsonResponse(for: request, body: [])
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
            accuracy: 1
        )
        XCTAssertFalse(record.syncPending)
    }
}

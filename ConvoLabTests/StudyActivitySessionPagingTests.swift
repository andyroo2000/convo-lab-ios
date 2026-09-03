import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testSynchronizationUsesRollingNinetyThreeDayWindowAndLoadsAnalytics() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let anchoredAnalyticsRequest = expectation(
            description: "Loads analytics for a selected calendar date"
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let components = try XCTUnwrap(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                )
                XCTAssertNotNil(components.queryItems?.first { $0.name == "timezone" }?.value)
                XCTAssertEqual(
                    components.queryItems?.first { $0.name == "weekStartsOn" }?.value,
                    "2"
                )
                let anchorDate = components.queryItems?
                    .first { $0.name == "anchorDate" }?.value
                XCTAssertNotNil(anchorDate)
                if anchorDate == "2026-06-15" {
                    anchoredAnalyticsRequest.fulfill()
                }
                return try analyticsResponse(for: request)
            }

            XCTAssertEqual(request.url?.path, "/api/study/activity-sessions")
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let fromValue = try XCTUnwrap(
                components.queryItems?.first { $0.name == "from" }?.value
            )
            let toValue = try XCTUnwrap(
                components.queryItems?.first { $0.name == "to" }?.value
            )
            let from = try Date(fromValue, strategy: .iso8601)
            let to = try Date(toValue, strategy: .iso8601)
            XCTAssertEqual(to.timeIntervalSince(from), 93 * 86_400, accuracy: 0.001)
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
        await store.loadAnalytics(
            anchorDate: try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        )
        await fulfillment(of: [anchoredAnalyticsRequest], timeout: 1)

        XCTAssertEqual(store.analytics?.range(.week)?.totalMs, 3_600_000)
        XCTAssertNil(store.syncErrorMessage)
    }

    func testEditableEntriesLoadInCursorPagesWithoutEagerPersistence() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/api/study/activity-sessions/editable")
            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            )
            XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "20")
            let cursor = query.first { $0.name == "cursor" }?.value
            let items: [[String: Any]]
            let nextCursor: String?
            if cursor == nil {
                items = [
                    studyActivityJSON(
                        id: "01K-FIRST",
                        clientSessionID: "first-editable",
                        startedAt: "2026-08-16T14:00:00Z"
                    ),
                ]
                nextCursor = "next-page"
            } else {
                XCTAssertEqual(cursor, "next-page")
                items = [
                    studyActivityJSON(
                        id: "01K-SECOND",
                        clientSessionID: "second-editable",
                        startedAt: "2026-08-15T14:00:00Z"
                    ),
                ]
                nextCursor = nil
            }
            let body: [String: Any] = [
                "items": items,
                "limit": 20,
                "nextCursor": nextCursor.map { $0 as Any } ?? NSNull(),
            ]
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: body)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.loadEditableSessions()

        XCTAssertEqual(store.editableSessions.map(\.clientSessionId), ["first-editable"])
        XCTAssertEqual(store.editableSessionsNextCursor, "next-page")

        await store.loadEditableSessions(reset: false)

        XCTAssertEqual(
            store.editableSessions.map(\.clientSessionId),
            ["first-editable", "second-editable"]
        )
        XCTAssertNil(store.editableSessionsNextCursor)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
    }

    func testEditingPaginatedRemoteEntryMaterializesItLocallyOnDemand() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/study/activity-sessions/editable"):
                let body: [String: Any] = [
                    "items": [
                        studyActivityJSON(
                            id: "01K-REMOTE",
                            clientSessionID: "remote-editable",
                            startedAt: "2026-08-16T14:00:00Z"
                        ),
                    ],
                    "limit": 20,
                    "nextCursor": NSNull(),
                ]
                return try Self.jsonResponse(for: request, body: body)
            case ("POST", "/api/study/activity-sessions/batch"):
                return try Self.jsonResponse(
                    for: request,
                    body: Self.batchSessions(from: request)
                )
            case ("GET", "/api/study/activity-analytics"):
                return try analyticsResponse(for: request)
            default:
                throw URLError(.badURL)
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        await store.loadEditableSessions()
        let session = try XCTUnwrap(store.editableSessions.first)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )

        _ = try await store.update(
            session: session,
            activity: .reading,
            name: "Edited after paging",
            startedAt: session.startedAt,
            duration: 600
        )

        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(saved.name, "Edited after paging")
        XCTAssertEqual(saved.activity, StudyActivityKind.reading.rawValue)
        XCTAssertFalse(saved.syncPending)
    }

    func testProductionSizedSynchronizationCompletesPromptly() async throws {
        let sessionCount = 568
        let startedAt = Date(timeIntervalSince1970: 1_755_000_000)
        let remote = (0..<sessionCount).map { index in
            StudyActivitySession(
                id: "server-\(index)",
                clientSessionId: "client-\(index)",
                category: .review,
                activity: .cardReview,
                source: .automatic,
                origin: .ios,
                name: nil,
                startedAt: startedAt.addingTimeInterval(Double(index)),
                endedAt: startedAt.addingTimeInterval(Double(index + 1)),
                durationMs: 1_000,
                audioPlaybackMs: nil,
                cardsCreated: nil
            )
        }
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        for session in remote {
            container.mainContext.insert(
                LocalStudyActivitySession(session: session, userID: 42)
            )
        }
        try container.mainContext.save()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let responseBody = try encoder.encode(remote)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-sessions" {
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
            return try analyticsResponse(for: request)
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        let started = ContinuousClock.now

        await store.synchronize()

        let elapsed = started.duration(to: .now)
        print("Production-sized study-time synchronization: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertNil(store.syncErrorMessage)
        XCTAssertEqual(store.sessions.count, sessionCount)
    }

    func testEditableEntryPagePreservesPendingLocalEdit() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let remote = makeSession(
            source: .manual,
            clientSessionId: "first-editable"
        )
        let local = LocalStudyActivitySession(session: remote, userID: 42)
        local.name = "Locally edited lesson"
        local.syncPending = true
        container.mainContext.insert(local)
        try container.mainContext.save()

        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            let body: [String: Any] = [
                "items": [
                    studyActivityJSON(
                        id: "01K-FIRST",
                        clientSessionID: "first-editable",
                        startedAt: "2026-08-16T14:00:00Z"
                    ),
                ],
                "limit": 20,
                "nextCursor": NSNull(),
            ]
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: body)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.loadEditableSessions()

        XCTAssertEqual(store.editableSessions.map(\.name), ["Locally edited lesson"])
        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertTrue(saved.syncPending)
        XCTAssertEqual(saved.name, "Locally edited lesson")
    }

    func testEditableEntryRefreshPreservesPendingLocalCreationMissingFromServerPage() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let localSession = makeSession(
            source: .manual,
            clientSessionId: "local-only"
        )
        let local = LocalStudyActivitySession(session: localSession, userID: 42)
        local.name = "Not pushed yet"
        local.syncPending = true
        container.mainContext.insert(local)
        try container.mainContext.save()

        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            let body: [String: Any] = [
                "items": [
                    studyActivityJSON(
                        id: "01K-SERVER",
                        clientSessionID: "server-only",
                        startedAt: "2026-08-16T14:00:00Z"
                    ),
                ],
                "limit": 20,
                "nextCursor": NSNull(),
            ]
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: body)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.loadEditableSessions()

        XCTAssertEqual(
            Set(store.editableSessions.map(\.clientSessionId)),
            ["local-only", "server-only"]
        )
        XCTAssertEqual(
            store.editableSessions.first { $0.clientSessionId == "local-only" }?.name,
            "Not pushed yet"
        )
    }

}

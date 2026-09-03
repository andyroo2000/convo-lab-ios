import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testAlreadyDeletedTombstoneDoesNotBlockPendingUpdates() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let deletedSession = makeSession(source: .manual)
        let tombstone = LocalStudyActivitySession(session: deletedSession, userID: 42)
        tombstone.isTombstone = true
        tombstone.syncPending = true
        container.mainContext.insert(tombstone)

        let pendingID = "018f22d2-6d38-7000-8000-000000000100"
        let pendingSession = StudyActivitySession(
            id: "server-session-2",
            clientSessionId: pendingID,
            category: .wanikani,
            activity: .wanikaniReview,
            source: .manual,
            name: "Pending WaniKani",
            startedAt: Date(timeIntervalSince1970: 1_753_736_400),
            endedAt: Date(timeIntervalSince1970: 1_753_737_000),
            durationMs: 600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
        let pending = LocalStudyActivitySession(session: pendingSession, userID: 42)
        pending.syncPending = true
        container.mainContext.insert(pending)
        try container.mainContext.save()
        let staleRemoteData = try Self.sessionData([deletedSession, pendingSession])

        let client = makeTombstoneSynchronizationClient(
            deletedSession: deletedSession,
            pendingSession: pendingSession,
            staleRemoteData: staleRemoteData
        )
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.synchronize()

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 2)
        let savedTombstone = try XCTUnwrap(
            records.first { $0.clientSessionID == deletedSession.clientSessionId }
        )
        XCTAssertTrue(savedTombstone.isTombstone)
        XCTAssertFalse(savedTombstone.syncPending)
        XCTAssertFalse(
            try XCTUnwrap(records.first { $0.clientSessionID == pendingSession.clientSessionId })
                .syncPending
        )
        XCTAssertEqual(store.sessions.first?.clientSessionId, pendingSession.clientSessionId)
        XCTAssertEqual(store.sessions.first?.name, pendingSession.name)
        XCTAssertEqual(store.sessions.first?.origin, .ios)
        XCTAssertNil(store.syncErrorMessage)
    }

    private func makeTombstoneSynchronizationClient(
        deletedSession: StudyActivitySession,
        pendingSession: StudyActivitySession,
        staleRemoteData: Data
    ) -> APIClient {
        let deletedSessionID = deletedSession.clientSessionId
        let pendingSessionID = pendingSession.clientSessionId
        return makeClient { request in
            try Self.tombstoneSynchronizationResponse(
                for: request,
                deletedSessionID: deletedSessionID,
                pendingSessionID: pendingSessionID,
                staleRemoteData: staleRemoteData
            )
        }
    }

    nonisolated private static func tombstoneSynchronizationResponse(
        for request: URLRequest,
        deletedSessionID: String,
        pendingSessionID: String,
        staleRemoteData: Data
    ) throws -> (HTTPURLResponse, Data) {
        let path = try XCTUnwrap(request.url).path
        let method = try XCTUnwrap(request.httpMethod)
        let handlers: [String: () throws -> (HTTPURLResponse, Data)] = [
            "DELETE /api/study/activity-sessions/\(deletedSessionID)": {
                try Self.jsonResponse(
                    for: request,
                    statusCode: 404,
                    body: ["message": "not found"]
                )
            },
            "POST /api/study/activity-sessions/batch": {
                let sessions = try Self.batchSessions(from: request)
                XCTAssertEqual(
                    try XCTUnwrap(sessions.first)["clientSessionId"] as? String,
                    pendingSessionID
                )
                return try Self.jsonResponse(for: request, body: sessions)
            },
            "GET /api/study/activity-sessions": {
                (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    staleRemoteData
                )
            },
            "GET /api/study/activity-analytics": {
                try analyticsResponse(for: request)
            },
        ]
        guard let handler = handlers["\(method) \(path)"] else {
            XCTFail("Unexpected tombstone synchronization request")
            throw URLError(.badURL)
        }
        return try handler()
    }
}

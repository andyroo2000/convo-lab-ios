import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testManualSessionCanBeEditedAndDeleted() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual, origin: .web)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()
        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/study/activity-sessions/batch"):
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                XCTAssertEqual(sessions.first?["activity"] as? String, "conversation")
                XCTAssertEqual(sessions.first?["durationMs"] as? Int, 2_700_000)
                XCTAssertEqual(sessions.first?["origin"] as? String, "web")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: sessions)
                )
            case ("DELETE", "/api/study/activity-sessions/\(original.clientSessionId)"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            case ("GET", "/api/study/activity-analytics"):
                return try analyticsResponse(for: request)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw URLError(.badURL)
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        _ = try await store.update(
            session: original,
            activity: .conversation,
            name: "iTalki lesson",
            startedAt: original.startedAt,
            duration: 45 * 60
        )

        XCTAssertEqual(store.sessions.first?.category, .conversation)
        XCTAssertEqual(store.sessions.first?.name, "iTalki lesson")
        XCTAssertEqual(store.sessions.first?.origin, .web)
        try await store.delete(session: try XCTUnwrap(store.sessions.first))
        XCTAssertTrue(store.sessions.isEmpty)
        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        let savedTombstone = try XCTUnwrap(records.first)
        XCTAssertTrue(savedTombstone.isTombstone)
        XCTAssertFalse(savedTombstone.syncPending)
    }

    func testFailedPushDoesNotLetStaleRemoteSessionOverwritePendingEdit() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let staleRemote = makeSession(source: .manual)
        let local = LocalStudyActivitySession(session: staleRemote, userID: 42)
        local.name = "Locally edited lesson"
        local.syncPending = true
        container.mainContext.insert(local)
        try container.mainContext.save()

        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/study/activity-sessions/batch"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"temporarily unavailable"}"#.utf8)
                )
            case ("GET", "/api/study/activity-sessions"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONEncoder().encode([staleRemote])
                )
            case ("GET", "/api/study/activity-analytics"):
                return try analyticsResponse(for: request)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw URLError(.badURL)
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.synchronize()

        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(saved.name, "Locally edited lesson")
        XCTAssertTrue(saved.syncPending)
        XCTAssertNotNil(store.syncErrorMessage)
    }

    func testAutomaticProviderAndSystemSessionsStayReadOnlyAfterPersistence() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let automatic = makeSession(source: .automatic)
        let provider = makeSession(
            source: .manual,
            origin: .googleCalendar,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000098"
        )
        let system = makeSession(
            source: .manual,
            origin: .system,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000097"
        )
        [automatic, provider, system].forEach {
            container.mainContext.insert(
                LocalStudyActivitySession(session: $0, userID: 42)
            )
        }
        try container.mainContext.save()
        let client = makeClient { request in
            XCTFail("Read-only deletion should not make a request: \(request)")
            throw URLError(.badURL)
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        for expected in [automatic, provider, system] {
            let persisted = try XCTUnwrap(
                store.sessions.first { $0.clientSessionId == expected.clientSessionId }
            )
            XCTAssertEqual(persisted.origin, expected.origin)
            do {
                try await store.delete(session: persisted)
                XCTFail("Read-only deletion should be rejected")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Automatically or externally recorded study time cannot be changed."
                )
            }
        }

        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertNil(store.storageWriteErrorMessage)
    }

    func testCalendarSessionWithoutALocalEventCannotSilentlyDiverge() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let calendarSession = makeSession(source: .calendar)
        container.mainContext.insert(
            LocalStudyActivitySession(session: calendarSession, userID: 42)
        )
        try container.mainContext.save()
        let client = makeClient { request in
            XCTFail("Unlinked calendar edit should not make a request: \(request)")
            throw URLError(.badURL)
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        do {
            _ = try await store.update(
                session: calendarSession,
                activity: .conversation,
                name: "Changed lesson",
                startedAt: calendarSession.startedAt,
                duration: 3_600
            )
            XCTFail("An unlinked calendar edit should be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The linked calendar event is not available on this device."
            )
        }

        XCTAssertEqual(store.sessions, [calendarSession])
        XCTAssertNil(store.storageWriteErrorMessage)
    }
}

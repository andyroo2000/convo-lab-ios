import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testNoOpStartPreservesUnresolvedErrorFromAnotherOperation() throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [2]
        )
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext,
            contextSaver: saves
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: .cardCreation, source: .manual))
        XCTAssertFalse(store.addCreatedCards())
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")

        XCTAssertTrue(store.start(activity: .cardCreation, source: .manual))

        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")
        XCTAssertTrue(store.addCreatedCards())
        XCTAssertNil(store.storageWriteErrorMessage)
        retainSaveFixtures(container, store, saves)
    }

    func testManualEditSaveFailureRollsBackRecordAndCanRetry() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [1]
        )
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext,
            contextSaver: saves
        )
        store.activate(userID: 42)
        let editedStart = original.startedAt.addingTimeInterval(300)

        do {
            _ = try await store.update(
                session: original,
                activity: .podcast,
                name: "Edited",
                startedAt: editedStart,
                duration: 900
            )
            XCTFail("Expected the injected save failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Forced save failure")
        }
        XCTAssertEqual(store.sessions, [original])
        XCTAssertEqual(try savedRecord(in: container).name, original.name)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")

        _ = try await store.update(
            session: original,
            activity: .podcast,
            name: "Edited",
            startedAt: editedStart,
            duration: 900
        )

        XCTAssertEqual(store.sessions.first?.activity, .podcast)
        XCTAssertEqual(store.sessions.first?.name, "Edited")
        XCTAssertNil(store.storageWriteErrorMessage)
        retainSaveFixtures(container, store, saves)
    }

    func testCalendarEditSaveFailureRestoresPreviousCalendarValues() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .calendar)
        let record = LocalStudyActivitySession(session: original, userID: 42)
        record.calendarEventIdentifier = "calendar-event"
        container.mainContext.insert(record)
        try container.mainContext.save()
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [1]
        )
        let calendar = DeterministicStudyCalendar()
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext,
            contextSaver: saves,
            calendar: calendar
        )
        store.activate(userID: 42)
        let editedStart = original.startedAt.addingTimeInterval(300)

        do {
            _ = try await store.update(
                session: original,
                activity: .podcast,
                name: "Edited",
                startedAt: editedStart,
                duration: 900
            )
            XCTFail("Expected the injected save failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Forced save failure")
        }

        XCTAssertEqual(
            calendar.updates,
            [
                .init(
                    identifier: "calendar-event",
                    title: "Edited",
                    start: editedStart,
                    end: editedStart.addingTimeInterval(900)
                ),
                .init(
                    identifier: "calendar-event",
                    title: original.name ?? original.activity.title,
                    start: original.startedAt,
                    end: original.endedAt
                ),
            ]
        )
        XCTAssertEqual(store.sessions, [original])
        XCTAssertEqual(try savedRecord(in: container).name, original.name)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")
        retainSaveFixtures(container, store, saves, calendar)
    }

    func testRecordCompletedSaveFailureRemovesCalendarEventAndCanRetry() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [1]
        )
        let calendar = DeterministicStudyCalendar()
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext,
            contextSaver: saves,
            calendar: calendar
        )
        store.activate(userID: 42)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            _ = try await store.recordCompleted(
                activity: .conversation,
                source: .manual,
                name: "Tutor lesson",
                startedAt: startedAt,
                duration: 1_800,
                addToCalendar: true
            )
            XCTFail("Expected the injected save failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Forced save failure")
        }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
        XCTAssertEqual(calendar.deletedIdentifiers, ["event-1"])
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")

        _ = try await store.recordCompleted(
            activity: .conversation,
            source: .manual,
            name: "Tutor lesson",
            startedAt: startedAt,
            duration: 1_800,
            addToCalendar: false
        )
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNil(store.storageWriteErrorMessage)
        retainSaveFixtures(container, store, saves, calendar)
    }

    func testRecordCompletedUsesStableClientIDForIdempotentShortcutImport() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.activate(userID: 42)

        for _ in 0..<2 {
            _ = try await store.recordCompleted(
                activity: .reading,
                source: .automatic,
                name: "Satori Reader",
                startedAt: startedAt,
                duration: 900,
                clientSessionID: "satori-session"
            )
        }

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.clientSessionID, "satori-session")
        XCTAssertEqual(records.first?.source, StudyActivitySource.automatic.rawValue)
        XCTAssertEqual(records.first?.activity, StudyActivityKind.reading.rawValue)
    }

    func testInactiveStoreKeepsCompletedShortcutImportRetryable() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )

        do {
            _ = try await store.recordCompleted(
                activity: .reading,
                source: .automatic,
                name: "Satori Reader",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 900,
                clientSessionID: "satori-session"
            )
            XCTFail("An inactive import should remain retryable")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Sign in before recording study time."
            )
        }

        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
    }

    func testStableClientIDDeduplicatesAgainstATombstone() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = LocalStudyActivitySession(
            session: makeSession(
                source: .manual,
                clientSessionId: "satori-session"
            ),
            userID: 42
        )
        existing.isTombstone = true
        container.mainContext.insert(existing)
        try container.mainContext.save()
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        store.activate(userID: 42)

        _ = try await store.recordCompleted(
            activity: .reading,
            source: .automatic,
            name: "Satori Reader",
            startedAt: startedAt,
            duration: 900,
            clientSessionID: "satori-session"
        )

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].isTombstone)
    }

    func testDeleteSaveFailureRollsBackTombstoneAndCanRetry() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [1]
        )
        let store = StudyTimeStore(
            api: makeClient { request in
                switch (request.httpMethod, request.url?.path) {
                case ("DELETE", _):
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
            },
            context: container.mainContext,
            contextSaver: saves
        )
        store.activate(userID: 42)

        do {
            try await store.delete(session: original)
            XCTFail("Expected the injected save failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Forced save failure")
        }
        XCTAssertEqual(store.sessions, [original])
        XCTAssertFalse(try savedRecord(in: container).isTombstone)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")

        try await store.delete(session: original)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.storageWriteErrorMessage)
        retainSaveFixtures(container, store, saves)
    }

    func testAnalyticsDurationsRespectSelectedCategories() {
        let bucket = StudyTimeAnalyticsBucket(
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_003_600),
            totalMs: 6_000_000,
            categories: [
                StudyActivityCategory.review.rawValue: 1_800_000,
                StudyActivityCategory.listen.rawValue: 3_000_000,
                StudyActivityCategory.conversation.rawValue: 1_200_000,
            ]
        )
        let analytics = StudyTimeAnalyticsRange(
            key: .today,
            startsAt: bucket.startsAt,
            endsAt: bucket.endsAt,
            totalMs: bucket.totalMs,
            categories: bucket.categories,
            buckets: [bucket]
        )
        let selection: Set<StudyActivityCategory> = [.review, .conversation]

        XCTAssertEqual(bucket.duration(for: selection), 3_000_000)
        XCTAssertEqual(analytics.duration(for: selection), 3_000_000)
    }

}

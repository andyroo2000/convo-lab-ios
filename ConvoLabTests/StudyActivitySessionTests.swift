import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyActivitySessionTests: XCTestCase {
    func testManualEntryRequestsEditableSessionsOnlyOnFirstExpansion() {
        XCTAssertFalse(
            StudyTimeManualEntryLoading.shouldRequestEntries(
                isExpanded: false,
                hasRequestedEntries: false
            )
        )
        XCTAssertTrue(
            StudyTimeManualEntryLoading.shouldRequestEntries(
                isExpanded: true,
                hasRequestedEntries: false
            )
        )
        XCTAssertFalse(
            StudyTimeManualEntryLoading.shouldRequestEntries(
                isExpanded: true,
                hasRequestedEntries: true
            )
        )
    }

    func testInactiveUserCannotSilentlyEditOrDeleteSession() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let session = makeSession(source: .manual)

        do {
            _ = try await store.update(
                session: session,
                activity: .reading,
                name: "Updated",
                startedAt: session.startedAt,
                duration: TimeInterval(session.durationMs) / 1_000
            )
            XCTFail("An inactive edit should fail instead of dismissing as successful")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This study entry is no longer available. Refresh and try again."
            )
        }

        do {
            try await store.delete(session: session)
            XCTFail("An inactive delete should fail instead of reporting success")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This study entry is no longer available. Refresh and try again."
            )
        }
        retainSaveFixtures(container, store)
    }

    // Confirmed with a weak saver and no unstructured task in the card-count
    // case: iOS 26 XCTest can double-free an injected SwiftData container at
    // method teardown. Keep this bounded set of six containers for the suite.
    private static var retainedSaveFixtures: [AnyObject] = []

    func testStartSaveFailureRollsBackActiveStateAndCanRetry() async throws {
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.activate(userID: 42)
        XCTAssertTrue(
            store.start(activity: .reading, source: .manual, at: startedAt)
        )

        XCTAssertFalse(
            store.start(
                activity: .podcast,
                source: .manual,
                at: startedAt.addingTimeInterval(60)
            )
        )
        XCTAssertEqual(store.active?.activity, .reading)
        XCTAssertEqual(store.active?.startedAt, startedAt)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            1
        )
        XCTAssertNil(try savedRecord(in: container).endedAt)

        XCTAssertTrue(
            store.start(
                activity: .podcast,
                source: .manual,
                at: startedAt.addingTimeInterval(60)
            )
        )
        XCTAssertEqual(store.active?.activity, .podcast)
        XCTAssertNil(store.storageWriteErrorMessage)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            2
        )
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.activity, .reading)
        XCTAssertEqual(
            store.sessions.first?.endedAt,
            startedAt.addingTimeInterval(60)
        )
        await store.synchronize()
        try await Task.sleep(for: .milliseconds(50))
        retainSaveFixtures(container, store, saves)
    }

    func testCardCountSaveFailureRollsBackActiveCountAndCanRetry() throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: [2]
        )
        let store = StudyTimeStore(
            api: makeClient { request in
                if request.url?.path == "/api/study/activity-sessions/batch" {
                    let body = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: requestBody(request)
                        ) as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(body["sessions"] as? [[String: Any]])
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
                if request.url?.path == "/api/study/activity-analytics" {
                    return try analyticsResponse(for: request)
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
            },
            context: container.mainContext,
            contextSaver: saves
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: .cardCreation, source: .manual))

        XCTAssertFalse(store.addCreatedCards())
        XCTAssertEqual(store.active?.cardsCreated, 0)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")
        XCTAssertEqual(try savedRecord(in: container).cardsCreated, 0)

        XCTAssertTrue(store.addCreatedCards())
        XCTAssertEqual(store.active?.cardsCreated, 1)
        XCTAssertNil(store.storageWriteErrorMessage)
        XCTAssertEqual(try savedRecord(in: container).cardsCreated, 1)
        retainSaveFixtures(container, store, saves)
    }

    func testFinishSaveFailureKeepsTimerActiveAndCanRetry() async throws {
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(60)
        store.activate(userID: 42)
        XCTAssertTrue(
            store.start(activity: .reading, source: .automatic, at: startedAt)
        )

        XCTAssertFalse(store.stop(at: endedAt))
        XCTAssertEqual(store.active?.startedAt, startedAt)
        XCTAssertEqual(store.storageWriteErrorMessage, "Forced save failure")
        XCTAssertNil(try savedRecord(in: container).endedAt)

        XCTAssertTrue(
            store.start(activity: .reading, source: .automatic, at: startedAt)
        )
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            "Forced save failure",
            "Resuming the same open timer must not hide its failed finish."
        )

        XCTAssertTrue(store.stop(at: endedAt))
        XCTAssertNil(store.active)
        XCTAssertNil(store.storageWriteErrorMessage)
        XCTAssertEqual(try savedRecord(in: container).endedAt, endedAt)
        await Task.yield()
        await store.synchronize()
        try await Task.sleep(for: .milliseconds(50))
        retainSaveFixtures(container, store, saves)
    }

    func testMissingActiveRecordClearsStrandedTimer() throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: .reading, source: .manual))
        let record = try savedRecord(in: container)
        container.mainContext.delete(record)
        try container.mainContext.save()

        XCTAssertFalse(store.stop())

        XCTAssertNil(store.active)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            "This study entry is no longer available. Refresh and try again."
        )
        retainSaveFixtures(container, store)
    }

    func testSwitchWithMissingActiveRecordClearsTimerWithoutInsertingDuplicate() throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: .reading, source: .manual))
        let record = try savedRecord(in: container)
        container.mainContext.delete(record)
        try container.mainContext.save()

        XCTAssertFalse(store.start(activity: .podcast, source: .manual))

        XCTAssertNil(store.active)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            "This study entry is no longer available. Refresh and try again."
        )
        retainSaveFixtures(container, store)
    }

    func testMissingCardCreationRecordClearsStrandedTimer() throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: .cardCreation, source: .manual))
        let record = try savedRecord(in: container)
        container.mainContext.delete(record)
        try container.mainContext.save()

        XCTAssertFalse(store.addCreatedCards())

        XCTAssertNil(store.active)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            "This study entry is no longer available. Refresh and try again."
        )
        retainSaveFixtures(container, store)
    }

    func testDeactivateSaveFailureReportsFailureAndReactivationResumesSameRow() async throws {
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
        XCTAssertTrue(store.start(activity: .reading, source: .manual))
        let originalID = try savedRecord(in: container).clientSessionID

        let didDeactivateCleanly = await store.deactivate()
        XCTAssertFalse(didDeactivateCleanly)
        XCTAssertNil(store.active)
        XCTAssertNil(store.storageWriteErrorMessage)
        XCTAssertNil(try savedRecord(in: container).endedAt)

        store.activate(userID: 42)
        XCTAssertEqual(store.active?.clientSessionID, originalID)
        XCTAssertTrue(store.start(activity: .reading, source: .manual))
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            1
        )
        retainSaveFixtures(container, store, saves)
    }

    func testAccountTransitionClearsPreviousUsersStorageWriteError() throws {
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

        store.activate(userID: 84)

        XCTAssertNil(store.storageWriteErrorMessage)
        retainSaveFixtures(container, store, saves)
    }

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

    private func savedRecord(
        in container: ModelContainer
    ) throws -> LocalStudyActivitySession {
        try XCTUnwrap(
            container.mainContext.fetch(
                FetchDescriptor<LocalStudyActivitySession>()
            ).first
        )
    }

    private func retainSaveFixtures(_ fixtures: AnyObject...) {
        Self.retainedSaveFixtures.append(contentsOf: fixtures)
    }

    func testAnalyticsRangesMapToExistingDrillDownViews() {
        XCTAssertEqual(StudyTimeRange.today.title, "Day")
        XCTAssertEqual(StudyTimeRange.year.drillDownTarget, .month)
        XCTAssertEqual(StudyTimeRange.month.drillDownTarget, .today)
        XCTAssertEqual(StudyTimeRange.week.drillDownTarget, .today)
        XCTAssertNil(StudyTimeRange.today.drillDownTarget)
        XCTAssertNil(StudyTimeRange.all.drillDownTarget)
    }

    func testStudyTimeSwipeRecognizerOnlyAcceptsHorizontalMovement() {
        XCTAssertTrue(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 40, y: 5)))
        XCTAssertTrue(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: -40, y: 5)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 5, y: 40)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 5, y: -40)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 20, y: 20)))
    }

    func testStudyTimeSwipeNavigationRequiresHorizontalThresholdAndAvailablePeriod() {
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 20, y: 2),
                projectedTranslationX: 80,
                canNavigateLater: false
            ),
            .previous
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: -80, y: 2),
                projectedTranslationX: -100,
                canNavigateLater: true
            ),
            .next
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: -80, y: 2),
                projectedTranslationX: -100,
                canNavigateLater: false
            ),
            .snapBack
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 80, y: 100),
                projectedTranslationX: 120,
                canNavigateLater: true
            ),
            .snapBack
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 60, y: 2),
                projectedTranslationX: 60,
                canNavigateLater: true
            ),
            .snapBack
        )
    }

    func testActivitiesMapToOnePrimaryCategory() {
        XCTAssertEqual(StudyActivityKind.cardReview.category, .review)
        XCTAssertEqual(StudyActivityKind.dailyAudio.category, .listen)
        XCTAssertEqual(StudyActivityKind.cardCreation.category, .create)
        XCTAssertEqual(StudyActivityKind.tv.category, .immerse)
        XCTAssertEqual(StudyActivityKind.podcast.category, .immerse)
        XCTAssertEqual(StudyActivityKind.reading.category, .immerse)
        XCTAssertEqual(StudyActivityKind.conversation.category, .conversation)
        XCTAssertEqual(StudyActivityKind.wanikaniReview.category, .wanikani)
        XCTAssertEqual(StudyActivityKind.other.category, .immerse)
    }

    func testPersistedLegacyCategoryIsCanonicalizedFromActivity() throws {
        let conversation = StudyActivitySession(
            id: nil,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000002",
            category: .conversation,
            activity: .conversation,
            source: .manual,
            name: "Lesson",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationMs: 3_600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
        let record = LocalStudyActivitySession(session: conversation, userID: 42)
        record.category = StudyActivityCategory.immerse.rawValue

        XCTAssertEqual(try XCTUnwrap(record.session).category, .conversation)
    }

    func testBatchEncodesRetrySafeClientIdentityAndOutputMetrics() throws {
        let session = StudyActivitySession(
            id: "server-session-1",
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
        XCTAssertEqual(encoded["id"] as? String, "server-session-1")
        XCTAssertEqual(encoded["category"] as? String, "create")
        XCTAssertEqual(encoded["activity"] as? String, "card_creation")
        XCTAssertEqual(encoded["origin"] as? String, "ios")
        XCTAssertEqual(encoded["cardsCreated"] as? Int, 12)

        let legacyData = try JSONEncoder().encode(
            StudyActivityBatchRequest(
                sessions: [makeSession(source: .manual, origin: .legacy)]
            )
        )
        let legacyBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        let legacySession = try XCTUnwrap(
            (legacyBody["sessions"] as? [[String: Any]])?.first
        )
        XCTAssertNil(legacySession["origin"])
    }

    func testSessionOriginDecodingIsBackwardAndForwardCompatible() throws {
        for (originValue, expected) in [
            (nil, StudyActivityOrigin.legacy),
            (NSNull(), .legacy),
            ("future_provider", .legacy),
            ("google_calendar", .googleCalendar),
        ] as [(Any?, StudyActivityOrigin)] {
            var object = studyActivitySessionJSONObject()
            if let originValue {
                object["origin"] = originValue
            }
            let data = try JSONSerialization.data(withJSONObject: object)

            let session = try studyActivityDecoder().decode(
                StudyActivitySession.self,
                from: data
            )

            XCTAssertEqual(session.origin, expected)
        }

        var futureObject = studyActivitySessionJSONObject()
        futureObject["origin"] = "future_provider"
        let future = try studyActivityDecoder().decode(
            StudyActivitySession.self,
            from: JSONSerialization.data(withJSONObject: futureObject)
        )
        XCTAssertEqual(future.origin, .legacy)
        XCTAssertTrue(future.hasUnknownOrigin)
        XCTAssertFalse(future.isEditable)

        let persisted = LocalStudyActivitySession(session: future, userID: 42)
        XCTAssertEqual(persisted.origin, "future_provider")
        let roundTripped = try XCTUnwrap(persisted.session)
        XCTAssertEqual(roundTripped.origin, .legacy)
        XCTAssertTrue(roundTripped.hasUnknownOrigin)
        XCTAssertFalse(roundTripped.isEditable)
    }

    func testProviderProvenanceIsSeparateFromCaptureSourceAndConservativelyEditable() {
        XCTAssertEqual(
            makeSession(source: .manual, origin: .googleCalendar).provider,
            .googleCalendar
        )
        XCTAssertEqual(makeSession(source: .calendar, origin: .ios).source, .calendar)
        XCTAssertNil(makeSession(source: .manual, origin: .web).provider)

        for origin in [StudyActivityOrigin.legacy, .ios, .web] {
            XCTAssertTrue(makeSession(source: .manual, origin: origin).isEditable)
        }
        XCTAssertTrue(makeSession(source: .calendar, origin: .ios).isEditable)
        XCTAssertFalse(makeSession(source: .automatic, origin: .ios).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .googleCalendar).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .waniKani).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .system).isEditable)
    }

    func testEditableEntriesCopyAndFilterMatchTheUIContract() {
        XCTAssertEqual(StudyTimeEditableEntries.sectionTitle, "Editable entries")
        XCTAssertEqual(
            StudyTimeEditableEntries.emptyDescription,
            "Timers and manually added study time you can edit appear here."
        )

        let editable = makeSession(source: .manual, origin: .ios)
        let automatic = makeSession(source: .automatic, origin: .ios)
        let provider = makeSession(source: .manual, origin: .googleCalendar)

        XCTAssertEqual(
            StudyTimeEditableEntries.filter([provider, automatic, editable]),
            [editable]
        )
    }

    func testOriginsSurviveLocalPersistenceWithSafeLegacyFallback() throws {
        for origin in [
            StudyActivityOrigin.legacy,
            .ios,
            .web,
            .googleCalendar,
            .waniKani,
            .system,
        ] {
            let record = LocalStudyActivitySession(
                session: makeSession(source: .manual, origin: origin),
                userID: 42
            )
            XCTAssertEqual(try XCTUnwrap(record.session).origin, origin)
        }

        let unknown = LocalStudyActivitySession(
            session: makeSession(source: .manual, origin: .web),
            userID: 42
        )
        unknown.origin = "future_provider"
        let unknownSession = try XCTUnwrap(unknown.session)
        XCTAssertEqual(unknownSession.origin, .legacy)
        XCTAssertTrue(unknownSession.hasUnknownOrigin)
        XCTAssertFalse(unknownSession.isEditable)

        let active = StudyTimeStore.ActiveSession(
            clientSessionID: "018f22d2-6d38-7000-8000-000000000097",
            category: .immerse,
            activity: .reading,
            source: .manual,
            name: nil,
            startedAt: Date(timeIntervalSince1970: 1_753_732_800),
            cardsCreated: 0
        )
        let local = LocalStudyActivitySession(active: active, userID: 42)
        local.endedAt = active.startedAt.addingTimeInterval(600)
        local.durationMs = 600_000
        XCTAssertEqual(try XCTUnwrap(local.session).origin, .ios)
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

    func testLeavingForegroundDoesNotStopManualTracking() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.activate(userID: 42)
        store.start(
            activity: .cardCreation,
            source: .manual,
            name: "Deck work",
            at: startedAt
        )

        store.stopForegroundAutomaticTracking(at: startedAt.addingTimeInterval(90))

        XCTAssertEqual(store.active?.source, .manual)
        XCTAssertEqual(store.active?.startedAt, startedAt)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertNil(record.endedAt)
        XCTAssertFalse(record.syncPending)

        // Finish the open SwiftData record before releasing the in-memory
        // container; simulator runtimes can otherwise tear it down mid-access.
        await store.deactivate(at: startedAt.addingTimeInterval(90))
    }

    func testLeavingForegroundKeepsBackgroundAudioTracking() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.activate(userID: 42)
        store.start(
            activity: .dailyAudio,
            source: .automatic,
            name: "Daily Audio",
            at: startedAt
        )

        store.stopForegroundAutomaticTracking(at: startedAt.addingTimeInterval(90))

        XCTAssertEqual(store.active?.activity, .dailyAudio)
        XCTAssertEqual(store.active?.startedAt, startedAt)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertNil(record.endedAt)
        XCTAssertFalse(record.syncPending)

        await store.deactivate(at: startedAt.addingTimeInterval(90))
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
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: recovered)
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
            accuracy: 1
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
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: body)
                )
            case ("POST", "/api/study/activity-sessions/batch"):
                let body = try requestBody(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let sessions = try XCTUnwrap(payload["sessions"] as? [[String: Any]])
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: sessions)
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

    func testFailedAnchoredAnalyticsRequestPreservesCurrentChart() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let components = try XCTUnwrap(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                )
                let anchorDate = components.queryItems?
                    .first { $0.name == "anchorDate" }?.value
                if anchorDate == "2026-06-15" {
                    return (
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url),
                            statusCode: 500,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"Analytics unavailable"}"#.utf8)
                    )
                }
                return try analyticsResponse(for: request)
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
        let currentAnalytics = try XCTUnwrap(store.analytics)

        let loaded = await store.loadAnalytics(
            anchorDate: try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        )

        XCTAssertFalse(loaded)
        XCTAssertEqual(store.analytics, currentAnalytics)
        XCTAssertEqual(store.syncErrorMessage, "Analytics unavailable")

        await store.synchronize()

        XCTAssertEqual(store.analytics, currentAnalytics)
        XCTAssertNil(store.syncErrorMessage)
    }

    func testPrefetchedAnalyticsCanBeSelectedWithoutChangingTheVisibleChartEarly() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    return try analyticsResponse(
                        for: request,
                        anchorDateOverride: "2026-06-14"
                    )
                }
                return try analyticsResponse(for: request)
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
        let visibleAnchor = try XCTUnwrap(store.analytics?.anchorDate)
        let nextAnchor = try Date("2026-06-15T12:00:00Z", strategy: .iso8601)

        let prefetched = await store.prefetchAnalytics(anchorDate: nextAnchor)

        XCTAssertTrue(prefetched)
        XCTAssertEqual(store.analytics?.anchorDate, visibleAnchor)
        XCTAssertNotNil(store.cachedAnalytics(anchorDate: nextAnchor))

        XCTAssertTrue(store.selectCachedAnalytics(anchorDate: nextAnchor))
        XCTAssertEqual(store.analytics?.anchorDate, "2026-06-14")

        await store.synchronize()

        XCTAssertNil(store.cachedAnalytics(anchorDate: nextAnchor))
    }

    func testLoadedAnalyticsUsesTheServerConfirmedAnchorForLaterSynchronization() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let confirmedAnchorRequest = expectation(description: "Uses confirmed analytics anchor")
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    return try analyticsResponse(
                        for: request,
                        anchorDateOverride: "2026-06-14"
                    )
                }
                if requestedAnchor == "2026-06-14" {
                    confirmedAnchorRequest.fulfill()
                }
                return try analyticsResponse(for: request)
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

        let loaded = await store.loadAnalytics(
            anchorDate: try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        )
        await store.synchronize()
        await fulfillment(of: [confirmedAnchorRequest], timeout: 1)

        XCTAssertTrue(loaded)
    }

    func testCacheInvalidationDiscardsAnOlderInFlightPrefetch() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (prefetchStarted, prefetchStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePrefetch, releasePrefetchContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            do {
                guard request.url?.path == "/api/study/activity-analytics" else {
                    completion(.failure(URLError(.badURL)))
                    return
                }
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    prefetchStartedContinuation.yield()
                    Task {
                        var releaseIterator = releasePrefetch.makeAsyncIterator()
                        _ = await releaseIterator.next()
                        completion(.success(try analyticsResponse(for: request)))
                    }
                } else {
                    completion(.success(try analyticsResponse(for: request)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        let staleAnchor = try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        let currentAnchor = try Date("2026-06-16T12:00:00Z", strategy: .iso8601)
        let stalePrefetch = Task {
            await store.prefetchAnalytics(anchorDate: staleAnchor)
        }
        var startedIterator = prefetchStarted.makeAsyncIterator()
        _ = await startedIterator.next()

        let currentLoaded = await store.loadAnalytics(anchorDate: currentAnchor)

        XCTAssertTrue(currentLoaded)
        releasePrefetchContinuation.yield()
        let stalePrefetchSucceeded = await stalePrefetch.value

        XCTAssertFalse(stalePrefetchSucceeded)
        XCTAssertNil(store.cachedAnalytics(anchorDate: staleAnchor))
        XCTAssertEqual(store.analytics?.anchorDate, "2026-06-16")
    }

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
        let staleRemoteData = try JSONSerialization.data(
            withJSONObject: [
                [
                    "id": deletedSession.id as Any,
                    "clientSessionId": deletedSession.clientSessionId,
                    "category": deletedSession.category.rawValue,
                    "activity": deletedSession.activity.rawValue,
                    "source": deletedSession.source.rawValue,
                    "origin": deletedSession.origin.rawValue,
                    "name": deletedSession.name as Any,
                    "startedAt": deletedSession.startedAt.ISO8601Format(),
                    "endedAt": deletedSession.endedAt.ISO8601Format(),
                    "durationMs": deletedSession.durationMs,
                ],
                [
                    "id": pendingSession.id as Any,
                    "clientSessionId": pendingSession.clientSessionId,
                    "category": pendingSession.category.rawValue,
                    "activity": pendingSession.activity.rawValue,
                    "source": pendingSession.source.rawValue,
                    "origin": pendingSession.origin.rawValue,
                    "name": pendingSession.name as Any,
                    "startedAt": pendingSession.startedAt.ISO8601Format(),
                    "endedAt": pendingSession.endedAt.ISO8601Format(),
                    "durationMs": pendingSession.durationMs,
                ],
            ]
        )

        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/study/activity-sessions/\(deletedSession.clientSessionId)"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"not found"}"#.utf8)
                )
            case ("POST", "/api/study/activity-sessions/batch"):
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                XCTAssertEqual(sessions.first?["clientSessionId"] as? String, pendingID)
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: sessions)
                )
            case ("GET", "/api/study/activity-sessions"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    staleRemoteData
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

    func testFailedDeleteDoesNotBlockPendingUpdates() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let deletedSession = makeSession(source: .manual)
        let tombstone = LocalStudyActivitySession(session: deletedSession, userID: 42)
        tombstone.isTombstone = true
        tombstone.syncPending = true
        container.mainContext.insert(tombstone)

        let pendingSession = StudyActivitySession(
            id: "server-session-3",
            clientSessionId: "018f22d2-6d38-7000-8000-000000000101",
            category: .conversation,
            activity: .conversation,
            source: .manual,
            name: "Pending lesson",
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
        let pendingID = pendingSession.clientSessionId

        let client = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/study/activity-sessions/\(deletedSession.clientSessionId)"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"temporarily unavailable"}"#.utf8)
                )
            case ("POST", "/api/study/activity-sessions/batch"):
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                XCTAssertEqual(
                    sessions.first?["clientSessionId"] as? String,
                    pendingID
                )
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: sessions)
                )
            case ("GET", "/api/study/activity-sessions"):
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONEncoder().encode([pendingSession])
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

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(
            try XCTUnwrap(records.first { $0.clientSessionID == deletedSession.clientSessionId })
                .syncPending
        )
        XCTAssertFalse(
            try XCTUnwrap(records.first { $0.clientSessionID == pendingSession.clientSessionId })
                .syncPending
        )
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

    func testCompletedEditIsNotOverwrittenByAStaleInFlightRefresh() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()

        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStaleGet, releaseStaleGetContinuation) = AsyncStream<Void>.makeStream()
        let staleBody = try JSONSerialization.data(
            withJSONObject: [
                [
                    "id": original.id as Any,
                    "clientSessionId": original.clientSessionId,
                    "category": original.category.rawValue,
                    "activity": original.activity.rawValue,
                    "source": original.source.rawValue,
                    "name": original.name as Any,
                    "startedAt": original.startedAt.ISO8601Format(),
                    "endedAt": original.endedAt.ISO8601Format(),
                    "durationMs": original.durationMs,
                ],
            ]
        )
        let client = makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/study/activity-sessions"):
                    getStartedContinuation.yield()
                    Task {
                        var releaseIterator = releaseStaleGet.makeAsyncIterator()
                        _ = await releaseIterator.next()
                        completion(.success((
                            HTTPURLResponse(
                                url: try XCTUnwrap(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!,
                            staleBody
                        )))
                    }
                case ("POST", "/api/study/activity-sessions/batch"):
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: requestBody(request)
                        ) as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                    completion(.success((
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url),
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        try JSONSerialization.data(withJSONObject: sessions)
                    )))
                case ("GET", "/api/study/activity-analytics"):
                    completion(.success(try analyticsResponse(for: request)))
                default:
                    XCTFail(
                        "Unexpected request: \(request.httpMethod ?? "") "
                            + "\(request.url?.path ?? "")"
                    )
                    completion(.failure(URLError(.badURL)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        let syncTask = Task { await store.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        defer { releaseStaleGetContinuation.yield() }

        _ = try await store.update(
            session: original,
            activity: .conversation,
            name: "Edited lesson",
            startedAt: original.startedAt,
            duration: 45 * 60
        )
        releaseStaleGetContinuation.yield()
        await syncTask.value

        let saved = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(saved.activity, .conversation)
        XCTAssertEqual(saved.name, "Edited lesson")
        XCTAssertEqual(saved.durationMs, 2_700_000)
    }

    func testStalePendingPushCannotAcknowledgeAReactivatedSessionsNewerEdit() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()

        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("POST", "/api/study/activity-sessions/batch"):
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: requestBody(request)
                        ) as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                    if pushCount.next() == 1 {
                        pushStartedContinuation.yield()
                        Task {
                            var releaseIterator = releasePush.makeAsyncIterator()
                            _ = await releaseIterator.next()
                            completion(.success((
                                HTTPURLResponse(
                                    url: try XCTUnwrap(request.url),
                                    statusCode: 200,
                                    httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"]
                                )!,
                                try JSONSerialization.data(withJSONObject: sessions)
                            )))
                        }
                    } else {
                        XCTAssertEqual(sessions.first?["name"] as? String, "New edit")
                        completion(.success((
                            HTTPURLResponse(
                                url: try XCTUnwrap(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!,
                            try JSONSerialization.data(withJSONObject: sessions)
                        )))
                    }
                case ("GET", "/api/study/activity-analytics"):
                    completion(.success(try analyticsResponse(for: request)))
                default:
                    XCTFail(
                        "Unexpected request: \(request.httpMethod ?? "") "
                            + "\(request.url?.path ?? "")"
                    )
                    completion(.failure(URLError(.badURL)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        let oldEdit = Task {
            try await store.update(
                session: original,
                activity: .conversation,
                name: "Old edit",
                startedAt: original.startedAt,
                duration: 30 * 60
            )
        }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()

        store.activate(userID: 43)
        store.activate(userID: 42)
        let reactivatedSession = try XCTUnwrap(store.sessions.first)
        let newEdit = Task {
            try await store.update(
                session: reactivatedSession,
                activity: .conversation,
                name: "New edit",
                startedAt: reactivatedSession.startedAt,
                duration: 45 * 60
            )
        }
        for _ in 0..<100 where store.sessions.first?.name != "New edit" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.sessions.first?.name, "New edit")
        releasePushContinuation.yield()
        _ = try await (oldEdit.value, newEdit.value)

        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(saved.name, "New edit")
        XCTAssertFalse(saved.syncPending)
        XCTAssertEqual(pushCount.current, 2)
    }

    func testStartingActivityDuringPendingPushSchedulesAcknowledgementRetry() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("POST", "/api/study/activity-sessions/batch"):
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: requestBody(request)
                        ) as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                    let response = {
                        completion(.success((
                            HTTPURLResponse(
                                url: try XCTUnwrap(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!,
                            try JSONSerialization.data(withJSONObject: sessions)
                        )))
                    }
                    if pushCount.next() == 1 {
                        pushStartedContinuation.yield()
                        Task {
                            var releaseIterator = releasePush.makeAsyncIterator()
                            _ = await releaseIterator.next()
                            try response()
                        }
                    } else {
                        try response()
                    }
                case ("GET", "/api/study/activity-analytics"):
                    completion(.success(try analyticsResponse(for: request)))
                default:
                    XCTFail(
                        "Unexpected request: \(request.httpMethod ?? "") "
                            + "\(request.url?.path ?? "")"
                    )
                    completion(.failure(URLError(.badURL)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        let startedAt = Date(timeIntervalSince1970: 1_753_732_800)
        store.activate(userID: 42)

        let completed = Task {
            try await store.recordCompleted(
                activity: .conversation,
                source: .manual,
                name: "Conversation",
                startedAt: startedAt,
                duration: 30 * 60
            )
        }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()

        store.start(
            activity: .cardReview,
            source: .automatic,
            at: startedAt.addingTimeInterval(2_000)
        )
        releasePushContinuation.yield()
        _ = try await completed.value

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        let saved = try XCTUnwrap(records.first { $0.endedAt != nil })
        XCTAssertFalse(saved.syncPending)
        XCTAssertEqual(pushCount.current, 2)
    }

    func testDeactivationInvalidatesAnalyticsBeforePendingPushSuspends() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()

        let (analyticsStarted, analyticsStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseAnalytics, releaseAnalyticsContinuation) = AsyncStream<Void>.makeStream()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/study/activity-analytics"):
                analyticsStartedContinuation.yield()
                Task {
                    do {
                        var iterator = releaseAnalytics.makeAsyncIterator()
                        _ = await iterator.next()
                        completion(.success(try analyticsResponse(for: request)))
                    } catch {
                        completion(.failure(error))
                    }
                }
            case ("POST", "/api/study/activity-sessions/batch"):
                pushStartedContinuation.yield()
                Task {
                    do {
                        var iterator = releasePush.makeAsyncIterator()
                        _ = await iterator.next()
                        let json = try XCTUnwrap(
                            JSONSerialization.jsonObject(
                                with: requestBody(request)
                            ) as? [String: Any]
                        )
                        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                        completion(.success((
                            HTTPURLResponse(
                                url: try XCTUnwrap(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!,
                            try JSONSerialization.data(withJSONObject: sessions)
                        )))
                    } catch {
                        completion(.failure(error))
                    }
                }
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)

        let analyticsTask = Task {
            await store.loadAnalytics(anchorDate: Date(timeIntervalSince1970: 1_753_732_800))
        }
        var analyticsStartedIterator = analyticsStarted.makeAsyncIterator()
        _ = await analyticsStartedIterator.next()

        let deactivationTask = Task { await store.deactivate() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        releaseAnalyticsContinuation.yield()
        _ = await analyticsTask.value

        XCTAssertNil(store.analytics)
        XCTAssertTrue(store.analyticsCache.isEmpty)

        releasePushContinuation.yield()
        let didDeactivate = await deactivationTask.value
        XCTAssertTrue(didDeactivate)
    }

    func testJoinedSynchronizationMarksTheLeadersOutcomeAsNonApplying() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseGet, releaseGetContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/study/activity-sessions"):
                getStartedContinuation.yield()
                Task {
                    var iterator = releaseGet.makeAsyncIterator()
                    _ = await iterator.next()
                    completion(.success((
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data("[]".utf8)
                    )))
                }
            case ("GET", "/api/study/activity-analytics"):
                do {
                    completion(.success(try analyticsResponse(for: request)))
                } catch {
                    completion(.failure(error))
                }
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        insights.activate(userID: 42)
        coordinator.activate(userID: 42)

        let leader = Task { await coordinator.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        let joiner = Task { await coordinator.synchronize() }
        await Task.yield()
        releaseGetContinuation.yield()

        let leaderOutcome = await leader.value
        let joinedOutcome = await joiner.value
        XCTAssertEqual(leaderOutcome?.shouldApply, true)
        XCTAssertEqual(joinedOutcome?.shouldApply, false)
    }

    func testJoinedPendingPushMarksTheLeadersOutcomeAsNonApplying() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            guard request.httpMethod == "POST",
                  request.url?.path == "/api/study/activity-sessions/batch"
            else {
                completion(.failure(URLError(.badURL)))
                return
            }
            pushStartedContinuation.yield()
            Task {
                var iterator = releasePush.makeAsyncIterator()
                _ = await iterator.next()
                do {
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: requestBody(request))
                            as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                    completion(.success((
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url),
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        try JSONSerialization.data(withJSONObject: sessions)
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        coordinator.activate(userID: 42)

        let leader = Task { await coordinator.pushPending() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        let joiner = Task { await coordinator.pushPending() }
        await Task.yield()
        releasePushContinuation.yield()

        let leaderOutcome = await leader.value
        let joinedOutcome = await joiner.value
        XCTAssertEqual(leaderOutcome?.shouldApply, true)
        XCTAssertEqual(joinedOutcome?.shouldApply, false)
    }

    func testSynchronizationSurfacesFailureFromAJoinedPendingPush() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/study/activity-sessions/batch"):
                let response = {
                    completion(.success((
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 503,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"Push unavailable"}"#.utf8)
                    )))
                }
                if pushCount.next() == 1 {
                    pushStartedContinuation.yield()
                    Task {
                        var iterator = releasePush.makeAsyncIterator()
                        _ = await iterator.next()
                        response()
                    }
                } else {
                    response()
                }
            case ("GET", "/api/study/activity-sessions"):
                completion(.success((
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("[]".utf8)
                )))
            case ("GET", "/api/study/activity-analytics"):
                do {
                    completion(.success(try analyticsResponse(for: request)))
                } catch {
                    completion(.failure(error))
                }
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        insights.activate(userID: 42)
        coordinator.activate(userID: 42)

        let pushLeader = Task { await coordinator.pushPending() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        let synchronization = Task { await coordinator.synchronize() }
        await Task.yield()
        releasePushContinuation.yield()

        let pushOutcome = await pushLeader.value
        let synchronizationOutcome = await synchronization.value
        XCTAssertNotNil(pushOutcome?.failureMessage)
        XCTAssertEqual(
            synchronizationOutcome?.failureMessage,
            pushOutcome?.failureMessage
        )
        XCTAssertEqual(synchronizationOutcome?.shouldApply, true)
    }

    func testSynchronizationSurfacesFailureAfterConcurrentLocalMutation() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseGet, releaseGetContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/study/activity-sessions"
            else {
                completion(.failure(URLError(.badURL)))
                return
            }
            getStartedContinuation.yield()
            Task {
                var iterator = releaseGet.makeAsyncIterator()
                _ = await iterator.next()
                completion(.success((
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Synchronization unavailable"}"#.utf8)
                )))
            }
        }
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)

        let synchronization = Task { await store.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        try store.deleteLocalData(userID: 42)
        releaseGetContinuation.yield()
        await synchronization.value

        XCTAssertNotNil(store.syncErrorMessage)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.active)
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}

@MainActor
private final class EmptyStudyTimeSnapshotCache: StudyTimeSnapshotCaching {
    func load(userID: Int, timeZone: String) -> StudyTimeSnapshot? { nil }
    func save(_ snapshot: StudyTimeSnapshot, userID: Int, timeZone: String) {}
    func remove(userID: Int) {}
}

@MainActor
private final class DeterministicStudyTimeSaves: StudyTimeContextSaving {
    private weak var context: ModelContext?
    private let failingAttempts: Set<Int>
    private var attempt = 0

    init(context: ModelContext, failingAttempts: Set<Int>) {
        self.context = context
        self.failingAttempts = failingAttempts
    }

    func save() throws {
        attempt += 1
        if failingAttempts.contains(attempt) {
            throw DeterministicStudyTimeSaveError.forced
        }
        guard let context else {
            throw DeterministicStudyTimeSaveError.fixtureDeallocated
        }
        try context.save()
    }
}

@MainActor
private final class DeterministicStudyCalendar: StudyCalendarProviding {
    struct Update: Equatable {
        let identifier: String
        let title: String
        let start: Date
        let end: Date
    }

    private(set) var deletedIdentifiers: [String] = []
    private(set) var updates: [Update] = []
    private var nextIdentifier = 1

    func addEvent(title: String, start: Date, end: Date) async throws -> String {
        defer { nextIdentifier += 1 }
        return "event-\(nextIdentifier)"
    }

    func updateEvent(
        identifier: String,
        title: String,
        start: Date,
        end: Date
    ) async throws {
        updates.append(.init(
            identifier: identifier,
            title: title,
            start: start,
            end: end
        ))
    }

    func deleteEvent(identifier: String) async throws {
        deletedIdentifiers.append(identifier)
    }
}

private enum DeterministicStudyTimeSaveError: LocalizedError {
    case forced
    case fixtureDeallocated

    var errorDescription: String? {
        switch self {
        case .forced:
            "Forced save failure"
        case .fixtureDeallocated:
            "The test persistence fixture was deallocated"
        }
    }
}

private func makeSession(
    source: StudyActivitySource,
    origin: StudyActivityOrigin = .ios,
    clientSessionId: String = "018f22d2-6d38-7000-8000-000000000099"
) -> StudyActivitySession {
    StudyActivitySession(
        id: "server-session-1",
        clientSessionId: clientSessionId,
        category: .immerse,
        activity: .tv,
        source: source,
        origin: origin,
        name: "Drama",
        startedAt: Date(timeIntervalSince1970: 1_753_732_800),
        endedAt: Date(timeIntervalSince1970: 1_753_734_600),
        durationMs: 1_800_000,
        audioPlaybackMs: nil,
        cardsCreated: nil
    )
}

private func studyActivitySessionJSONObject() -> [String: Any] {
    [
        "id": "server-session-1",
        "clientSessionId": "018f22d2-6d38-7000-8000-000000000099",
        "category": "immerse",
        "activity": "tv",
        "source": "manual",
        "name": "Drama",
        "startedAt": "2026-07-28T20:00:00Z",
        "endedAt": "2026-07-28T20:30:00Z",
        "durationMs": 1_800_000,
    ]
}

private func studyActivityJSON(
    id: String,
    clientSessionID: String,
    startedAt: String
) -> [String: Any] {
    [
        "id": id,
        "clientSessionId": clientSessionID,
        "category": "immerse",
        "activity": "tv",
        "source": "manual",
        "origin": "ios",
        "name": "Drama",
        "startedAt": startedAt,
        "endedAt": startedAt,
        "durationMs": 1_800_000,
    ]
}

private func studyActivityDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func analyticsResponse(
    for request: URLRequest,
    anchorDateOverride: String? = nil
) throws -> (HTTPURLResponse, Data) {
    let requestURL = try XCTUnwrap(request.url)
    let anchorDate = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == "anchorDate" }?
        .value ?? "2026-07-28"
    let body: [String: Any] = [
        "generatedAt": "2026-07-28T20:00:00Z",
        "anchorDate": anchorDateOverride ?? anchorDate,
        "timezone": "America/New_York",
        "ranges": [
            [
                "key": "week",
                "startsAt": "2026-07-27T04:00:00Z",
                "endsAt": "2026-07-28T20:00:00Z",
                "totalMs": 3_600_000,
                "categories": [
                    "review": 1_800_000,
                    "listen": 0,
                    "create": 0,
                    "immerse": 0,
                    "conversation": 1_800_000,
                    "wanikani": 0,
                ],
                "buckets": [
                    [
                        "startsAt": "2026-07-28T04:00:00Z",
                        "endsAt": "2026-07-28T20:00:00Z",
                        "totalMs": 3_600_000,
                        "categories": [
                            "review": 1_800_000,
                            "listen": 0,
                            "create": 0,
                            "immerse": 0,
                            "conversation": 1_800_000,
                            "wanikani": 0,
                        ],
                    ],
                ],
            ],
        ],
    ]
    return (
        HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        try JSONSerialization.data(withJSONObject: body)
    )
}

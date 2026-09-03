import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testServerActivityCategoryMapReclassifiesLocalStateAndSurvivesOfflineRelaunch() throws {
        let defaultsName = "StudyActivitySessionTests.category-authority.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let firstContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        let firstStore = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: firstContainer.mainContext,
            activityCategoryDefaults: defaults
        )
        firstStore.activate(userID: 42)

        XCTAssertTrue(firstStore.start(activity: .reading, source: .manual))
        XCTAssertEqual(firstStore.active?.category, .immerse)
        firstContainer.mainContext.insert(LocalStudyActivitySession(
            active: StudyTimeActiveSession(
                clientSessionID: "other-account-active",
                category: .immerse,
                activity: .reading,
                source: .manual,
                name: nil,
                startedAt: .now,
                cardsCreated: 0
            ),
            userID: 84
        ))
        try firstContainer.mainContext.save()

        firstStore.applyStudyActivityCapabilities(.init(categoriesByActivity: [
            StudyActivityKind.reading.rawValue: StudyActivityCategory.conversation.rawValue,
        ]))

        XCTAssertEqual(firstStore.active?.category, .conversation)
        let persistedRecords = try firstContainer.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(
            persistedRecords.first { $0.userID == 42 }?.category,
            "conversation"
        )
        XCTAssertEqual(
            persistedRecords.first { $0.userID == 84 }?.category,
            "immerse"
        )

        let otherAccountContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        let otherAccountStore = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: otherAccountContainer.mainContext,
            activityCategoryDefaults: defaults
        )
        otherAccountStore.activate(userID: 84)
        XCTAssertTrue(otherAccountStore.start(activity: .reading, source: .manual))
        XCTAssertEqual(otherAccountStore.active?.category, .immerse)

        let offlineContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        let offlineStore = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: offlineContainer.mainContext,
            activityCategoryDefaults: defaults
        )
        offlineStore.activate(userID: 42)
        XCTAssertTrue(offlineStore.start(activity: .reading, source: .manual))
        XCTAssertEqual(offlineStore.active?.category, .conversation)
        retainSaveFixtures(firstContainer, firstStore)
        retainSaveFixtures(otherAccountContainer, otherAccountStore)
        retainSaveFixtures(offlineContainer, offlineStore)
    }

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
        let fixture = try missingRecordFixture(activity: .reading)

        XCTAssertFalse(fixture.store.stop())

        try assertMissingRecordCleared(fixture)
    }

    func testSwitchWithMissingActiveRecordClearsTimerWithoutInsertingDuplicate() throws {
        let fixture = try missingRecordFixture(activity: .reading)

        XCTAssertFalse(fixture.store.start(activity: .podcast, source: .manual))

        try assertMissingRecordCleared(fixture, expectedRecordCount: 0)
    }

    func testMissingCardCreationRecordClearsStrandedTimer() throws {
        let fixture = try missingRecordFixture(activity: .cardCreation)

        XCTAssertFalse(fixture.store.addCreatedCards())

        try assertMissingRecordCleared(fixture)
    }

    private func missingRecordFixture(
        activity: StudyActivityKind
    ) throws -> (container: ModelContainer, store: StudyTimeStore) {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        store.activate(userID: 42)
        XCTAssertTrue(store.start(activity: activity, source: .manual))
        container.mainContext.delete(try savedRecord(in: container))
        try container.mainContext.save()
        return (container, store)
    }

    private func assertMissingRecordCleared(
        _ fixture: (container: ModelContainer, store: StudyTimeStore),
        expectedRecordCount: Int? = nil
    ) throws {
        XCTAssertNil(fixture.store.active)
        XCTAssertTrue(fixture.store.sessions.isEmpty)
        if let expectedRecordCount {
            XCTAssertEqual(
                try fixture.container.mainContext.fetchCount(
                    FetchDescriptor<LocalStudyActivitySession>()
                ),
                expectedRecordCount
            )
        }
        XCTAssertEqual(
            fixture.store.storageWriteErrorMessage,
            "This study entry is no longer available. Refresh and try again."
        )
        retainSaveFixtures(fixture.container, fixture.store)
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

}

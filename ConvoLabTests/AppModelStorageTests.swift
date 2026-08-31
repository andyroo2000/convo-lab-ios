import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AppModelStorageTests: XCTestCase {
    private nonisolated(unsafe) static var retainedObservableStores: [AnyObject] = []

    private enum TestFailure: Error {
        case unavailable
    }

    func testLaunchPublishesCachedStudyDataBeforeRefresh() throws {
        let user = CurrentUser(
            id: 42,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = AppModelCachedCredentialStore(values: [
            "learning-os-mobile-token": "cached-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let studyContainer = try Persistence.makeContainer(inMemory: true)
        let card = reviewCard()
        studyContainer.mainContext.insert(LocalCardRecord(
            card: card,
            userID: user.id,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try studyContainer.mainContext.save()
        let defaultsName = "AppModelStorageTests.cached-launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in studyContainer },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            },
            makeAuthStore: { api in
                AuthStore(api: api, keychain: credentials)
            },
            accountDeletionCleanupDefaults: defaults
        )

        guard case let .signedIn(restoredUser) = model.auth.state else {
            return XCTFail("Expected cached authentication at construction")
        }
        XCTAssertEqual(restoredUser.id, user.id)
        XCTAssertEqual(restoredUser.email, user.email)
        XCTAssertEqual(model.study.cards.map(\.id), [card.id])
        XCTAssertEqual(model.study.libraryCards.map(\.id), [card.id])
        XCTAssertEqual(
            model.study.learningItems.map(\.representativeCard.id),
            [card.id]
        )
        Self.retainedObservableStores.append(model)
    }

    func testSatoriImportRecordsAcknowledgesAndScopesPendingSessions() async throws {
        let user = CurrentUser(
            id: 42,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = AppModelCachedCredentialStore(values: [
            "learning-os-mobile-token": "cached-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let defaultsName = "AppModelStorageTests.satori-import.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let tracking = SatoriReaderTrackingStore(defaults: defaults)
        let timeContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in timeContainer },
            makeAPIClient: makeOfflineClient,
            makeAuthStore: { api in
                AuthStore(api: api, keychain: credentials)
            },
            satoriReaderTracking: tracking,
            accountDeletionCleanupDefaults: defaults
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        tracking.recordStart(at: startedAt)
        tracking.recordStop(at: startedAt.addingTimeInterval(600))
        let expected = try XCTUnwrap(tracking.pendingSessions(userID: user.id).first)
        tracking.setActiveUserID(84)
        tracking.recordStart(at: startedAt.addingTimeInterval(1_000))
        tracking.recordStop(at: startedAt.addingTimeInterval(1_600))
        tracking.setActiveUserID(user.id)

        await model.importPendingSatoriReaderSessions()

        let records = try timeContainer.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].userID, user.id)
        XCTAssertEqual(records[0].clientSessionID, expected.id)
        XCTAssertEqual(records[0].activity, StudyActivityKind.reading.rawValue)
        XCTAssertEqual(records[0].source, StudyActivitySource.automatic.rawValue)
        XCTAssertTrue(tracking.pendingSessions(userID: user.id).isEmpty)
        XCTAssertEqual(tracking.pendingSessions(userID: 84).count, 1)
        Self.retainedObservableStores.append(model)
    }

    func testSatoriImportFailureLeavesCurrentAndLaterSessionsQueued() async throws {
        let user = CurrentUser(
            id: 42,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = AppModelCachedCredentialStore(values: [
            "learning-os-mobile-token": "cached-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let defaultsName = "AppModelStorageTests.satori-retry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let tracking = SatoriReaderTrackingStore(defaults: defaults)
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { inMemory in
                guard inMemory else { throw TestFailure.unavailable }
                return try StudyTimePersistence.makeContainer(inMemory: true)
            },
            makeAPIClient: makeOfflineClient,
            makeAuthStore: { api in
                AuthStore(api: api, keychain: credentials)
            },
            satoriReaderTracking: tracking,
            accountDeletionCleanupDefaults: defaults
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [TimeInterval(0), 1_000] {
            tracking.recordStart(at: startedAt.addingTimeInterval(offset))
            tracking.recordStop(at: startedAt.addingTimeInterval(offset + 600))
        }

        await model.importPendingSatoriReaderSessions()

        XCTAssertEqual(tracking.pendingSessions(userID: user.id).count, 2)
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
        Self.retainedObservableStores.append(model)
    }

    func testSynchronizationLoadsCapabilitiesBeforeAuthorityDependentStudySync() async throws {
        let user = CurrentUser(
            id: 42,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = AppModelCachedCredentialStore(values: [
            "learning-os-mobile-token": "cached-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let paths = LockedRequestPaths()
        let capabilityData = try JSONEncoder().encode(StudyCapabilities.fallback)
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            guard path == "/api/study/capabilities" else {
                throw URLError(.notConnectedToInternet)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                capabilityData
            )
        }
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let defaultsName = "AppModelStorageTests.capability-order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            },
            makeAPIClient: { baseURL in
                APIClient(
                    baseURL: baseURL,
                    session: URLSession(configuration: configuration)
                )
            },
            makeAuthStore: { api in
                AuthStore(api: api, keychain: credentials)
            },
            accountDeletionCleanupDefaults: defaults
        )

        await model.synchronize()

        XCTAssertEqual(paths.values.first, "/api/study/capabilities")
        Self.retainedObservableStores.append(model)
    }

    func testLaunchReportsMainStoreFallbackAndRejectsCardWrites() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { inMemory in
                guard inMemory else { throw TestFailure.unavailable }
                return try Persistence.makeContainer(inMemory: true)
            },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(model.storageStatus.study, .temporary)
        XCTAssertEqual(model.storageStatus.studyTime, .persistent)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "Study data is using temporary storage. Card and review changes are disabled until you relaunch the app."
        )

        model.study.activate(userID: 42)
        do {
            try await model.study.createCard(
                expression: "猫",
                reading: "ねこ",
                meaning: "cat"
            )
            XCTFail("Expected temporary storage to reject the card write")
        } catch let error as StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, .study)
        }
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<LocalCardRecord>()),
            0
        )
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<PendingMutation>()),
            0
        )

        let card = reviewCard()
        do {
            try await model.study.updateCard(card, draft: StudyCardDraft(card: card))
            XCTFail("Expected temporary storage to reject the card update")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            try await model.study.deleteCard(card)
            XCTFail("Expected temporary storage to reject the card delete")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            _ = try await model.study.regenerateImage(
                for: card,
                prompt: "new image",
                placement: .prompt
            )
            XCTFail("Expected temporary storage to reject the media update")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            try await model.study.retryPendingDraftCommits()
            XCTFail("Expected temporary storage to reject the draft retry")
        } catch {
            assertStorageError(error, domain: .study)
        }
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<PendingMutation>()),
            0
        )

        let eventID = await model.study.recordReview(
            card: card,
            rating: .good,
            duration: .seconds(2)
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(
            model.study.storageWriteErrorMessage,
            StorageWriteUnavailableError(domain: .study).localizedDescription
        )
        XCTAssertEqual(model.study.syncStatus, .idle)
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<PendingMutation>()),
            0
        )
    }

    func testLaunchReportsStudyTimeFallbackAndRejectsTimerWrites() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in
                try Persistence.makeContainer(inMemory: true)
            },
            makeStudyTimeContainer: { inMemory in
                guard inMemory else { throw TestFailure.unavailable }
                return try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(model.storageStatus.study, .persistent)
        XCTAssertEqual(model.storageStatus.studyTime, .temporary)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "Study time is using temporary storage. Recording and editing study time are disabled until you relaunch the app."
        )

        model.studyTime.start(activity: .reading, source: .manual)
        XCTAssertNil(model.studyTime.syncErrorMessage)

        model.studyTime.activate(userID: 42)
        model.studyTime.start(activity: .reading, source: .manual)

        XCTAssertNil(model.studyTime.active)
        XCTAssertEqual(
            model.studyTime.storageWriteErrorMessage,
            StorageWriteUnavailableError(domain: .studyTime).localizedDescription
        )
        XCTAssertNil(model.studyTime.syncErrorMessage)
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )

        let session = studyTimeSession()
        do {
            _ = try await model.studyTime.update(
                session: session,
                activity: .reading,
                name: "Edited",
                startedAt: .now,
                duration: 300
            )
            XCTFail("Expected temporary storage to reject the study-time update")
        } catch {
            assertStorageError(error, domain: .studyTime)
        }
        do {
            try await model.studyTime.delete(session: session)
            XCTFail("Expected temporary storage to reject the study-time delete")
        } catch {
            assertStorageError(error, domain: .studyTime)
        }
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )

        do {
            _ = try await model.studyTime.recordCompleted(
                activity: .reading,
                source: .manual,
                name: "Reading",
                startedAt: .now,
                duration: 600
            )
            XCTFail("Expected temporary storage to reject the completed entry")
        } catch let error as StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, .studyTime)
        }
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
    }

    func testLaunchReportsBothFallbacks() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: fallbackOnly { try Persistence.makeContainer(inMemory: $0) },
            makeStudyTimeContainer: fallbackOnly(StudyTimePersistence.makeContainer)
        )

        XCTAssertEqual(model.storageStatus.study, .temporary)
        XCTAssertEqual(model.storageStatus.studyTime, .temporary)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "ConvoLab is using temporary storage. Card, review, and study-time changes are disabled until you relaunch the app."
        )
    }

    func testLaunchReportsHealthyStoresWithoutWarning() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(
            model.storageStatus,
            StorageStatus(study: .persistent, studyTime: .persistent)
        )
        XCTAssertNil(model.storageStatus.warningMessage)
    }

    private func fallbackOnly(
        _ factory: @escaping (Bool) throws -> ModelContainer
    ) -> (Bool) throws -> ModelContainer {
        { inMemory in
            guard inMemory else { throw TestFailure.unavailable }
            return try factory(true)
        }
    }

    private func testConfiguration() -> AppConfiguration {
        AppConfiguration(apiBaseURL: URL(string: "https://example.com")!)
    }

    private func makeOfflineClient(baseURL: URL) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: baseURL,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertStorageError(_ error: any Error, domain: StorageDomain) {
        if let error = error as? StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, domain)
        } else {
            XCTFail("Expected StorageWriteUnavailableError, got \(error)")
        }
    }

    private func reviewCard() -> StudyCard {
        StudyCard(
            id: "01J0000000000000000000000RV",
            syncId: nil,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("復習")]),
            answer: .object(["meaning": .string("review")]),
            state: .init(
                dueAt: .now,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: .object([:]),
                source: .object([:])
            ),
            answerAudioSource: "missing",
            masteryLevel: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func studyTimeSession() -> StudyActivitySession {
        StudyActivitySession(
            id: "server-study-time-session",
            clientSessionId: "study-time-session",
            category: .immerse,
            activity: .reading,
            source: .manual,
            name: "Reading",
            startedAt: .now.addingTimeInterval(-600),
            endedAt: .now,
            durationMs: 600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
    }
}

@MainActor
private final class AppModelCachedCredentialStore: CredentialStore {
    private var values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(_ value: String, account: String) throws {
        values[account] = value
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func remove(account: String) throws {
        values[account] = nil
    }
}

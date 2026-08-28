import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AccountDeletionCleanupTests: XCTestCase {
    // The iOS 26 XCTest runtime can double-free closure-backed fixture teardown
    // state. Retain these short-lived probes until the test process exits.
    private nonisolated(unsafe) static var retainedFixtures: [AnyObject] = []

    func testCleanupAttemptsEveryDomainAndRetainsEveryFailure() async throws {
        let defaults = try makeDefaults()
        let ledger = AccountDeletionCleanupLedger(defaults: defaults)
        let probe = CleanupProbe(failing: [.study, .studyTime])
        let coordinator = AccountDeletionCleanupCoordinator(
            ledger: ledger,
            operations: probe.operations
        )
        coordinator.scheduleCleanup(userID: 42)

        let failures = await coordinator.retryPendingCleanup()

        XCTAssertEqual(
            probe.attempted.count,
            AccountDeletionCleanupDomain.allCases.count
        )
        XCTAssertTrue(AccountDeletionCleanupDomain.allCases.allSatisfy {
            probe.attempted.contains($0)
        })
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.contains { $0.domain == .study })
        XCTAssertTrue(failures.contains { $0.domain == .studyTime })
        XCTAssertEqual(ledger.pendingItems.count, 2)
        XCTAssertTrue(ledger.pendingItems.contains {
            $0.userID == 42 && $0.domain == .study
        })
        XCTAssertTrue(ledger.pendingItems.contains {
            $0.userID == 42 && $0.domain == .studyTime
        })
        Self.retainedFixtures.append(probe)
        Self.retainedFixtures.append(coordinator)
    }

    func testRelaunchRetriesOnlyDurablyPendingCleanupDomains() async throws {
        let defaults = try makeDefaults()
        let firstLedger = AccountDeletionCleanupLedger(defaults: defaults)
        let firstProbe = CleanupProbe(failing: [.study, .studyTime])
        let firstCoordinator = AccountDeletionCleanupCoordinator(
            ledger: firstLedger,
            operations: firstProbe.operations
        )
        firstCoordinator.scheduleCleanup(userID: 42)
        let firstFailures = await firstCoordinator.retryPendingCleanup()
        XCTAssertEqual(firstFailures.count, 2)

        let relaunchedProbe = CleanupProbe()
        let relaunchedLedger = AccountDeletionCleanupLedger(defaults: defaults)
        let relaunchedCoordinator = AccountDeletionCleanupCoordinator(
            ledger: relaunchedLedger,
            operations: relaunchedProbe.operations
        )

        XCTAssertEqual(relaunchedCoordinator.pendingFailures.count, 2)
        XCTAssertTrue(relaunchedCoordinator.pendingFailures.allSatisfy { $0.userID == 42 })
        let relaunchedFailures = await relaunchedCoordinator.retryPendingCleanup()
        XCTAssertTrue(relaunchedFailures.isEmpty)
        XCTAssertEqual(relaunchedProbe.attempted.count, 2)
        XCTAssertTrue(relaunchedProbe.attempted.contains(.study))
        XCTAssertTrue(relaunchedProbe.attempted.contains(.studyTime))
        XCTAssertTrue(relaunchedLedger.pendingItems.isEmpty)
        Self.retainedFixtures.append(firstProbe)
        Self.retainedFixtures.append(firstCoordinator)
        Self.retainedFixtures.append(relaunchedProbe)
        Self.retainedFixtures.append(relaunchedCoordinator)
    }

    func testCleanupRetryRemainsScopedToDeletedUser() async throws {
        let defaults = try makeDefaults()
        let ledger = AccountDeletionCleanupLedger(defaults: defaults)
        ledger.schedule(userID: 42)
        let probe = CleanupProbe()
        let coordinator = AccountDeletionCleanupCoordinator(
            ledger: ledger,
            operations: probe.operations
        )
        Self.retainedFixtures.append(probe)
        Self.retainedFixtures.append(coordinator)

        let failures = await coordinator.retryPendingCleanup()

        XCTAssertEqual(Set(probe.attemptedUserIDs), [42])
        XCTAssertFalse(probe.attemptedUserIDs.contains(84))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(ledger.pendingItems.isEmpty)
    }

    func testSignedOutLaunchRetriesDeletionCleanupBeforeAuthenticationRestore() async throws {
        let defaults = try makeDefaults()
        let ledger = AccountDeletionCleanupLedger(defaults: defaults)
        ledger.schedule(userID: 42)
        let container = try Persistence.makeContainer(inMemory: true)
        let timeContainer = try StudyTimePersistence.makeContainer(inMemory: true)
        try insertCard(userID: 42, into: container)
        timeContainer.mainContext.insert(
            LocalStudyActivitySession(session: studyTimeSession(), userID: 42)
        )
        try timeContainer.mainContext.save()
        let model = AppModel(
            configuration: AppConfiguration(
                apiBaseURL: URL(string: "https://example.test")!
            ),
            makeContainer: { _ in container },
            makeStudyTimeContainer: { _ in timeContainer },
            makeAuthStore: { api in
                AuthStore(api: api, keychain: EmptyCredentialStore())
            },
            accountDeletionCleanupDefaults: defaults
        )

        await model.start()

        guard case .signedOut = model.auth.state else {
            return XCTFail("Cleanup retry must not require an authenticated account")
        }
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<LocalCardRecord>()),
            0
        )
        XCTAssertEqual(
            try timeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
        XCTAssertTrue(ledger.pendingItems.isEmpty)
        XCTAssertTrue(model.accountDeletionCleanupFailures.isEmpty)
        XCTAssertEqual(model.accountDeletionCleanupStatus, .complete)
        XCTAssertFalse(model.shouldShowAccountDeletionCleanupWarning)
    }

    func testConfirmedAccountDeletionSchedulesEveryCleanupBeforeFailedAttempts() async throws {
        let defaults = try makeDefaults()
        let user = CurrentUser(
            id: 42,
            name: "Deleted User",
            email: "deleted@example.com",
            emailVerifiedAt: nil
        )
        let cardCatalogCache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cardCatalogCache.save(
            StudyCardCatalogSnapshot(
                savedAt: .now,
                newCardQueue: [],
                newCardQueueTotal: 0,
                newCardQueueNextCursor: nil,
                newCardQueueRefreshedAt: .now,
                learningItems: [],
                learningItemsNextCursor: nil,
                learningItemsRefreshedAt: .now
            ),
            userID: user.id
        )
        cardCatalogCache.saveManualDrafts(
            StudyManualDraftSnapshot(savedAt: .now, drafts: [], refreshedAt: .now),
            userID: user.id
        )
        let credentials = CleanupCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let authClient = makeClient { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                return Self.response(data: Data(
                    #"{"data":{"id":42,"name":"Deleted User","email":"deleted@example.com","email_verified_at":null}}"#.utf8
                ))
            case ("/api/me", "DELETE"):
                return Self.response(statusCode: 204)
            default:
                throw URLError(.badURL)
            }
        }
        let model = AppModel(
            configuration: AppConfiguration(
                apiBaseURL: URL(string: "https://example.test")!
            ),
            makeContainer: fallbackOnly { inMemory in
                try Persistence.makeContainer(inMemory: inMemory)
            },
            makeStudyTimeContainer: fallbackOnly(StudyTimePersistence.makeContainer),
            makeAuthStore: { _ in
                AuthStore(api: authClient, keychain: credentials)
            },
            accountDeletionCleanupDefaults: defaults
        )
        await model.auth.restore()

        let deleted = await model.deleteAccount(currentPassword: "password")

        XCTAssertTrue(deleted)
        guard case .signedOut = model.auth.state else {
            return XCTFail("Server-confirmed deletion must remain signed out")
        }
        let pending = AccountDeletionCleanupLedger(defaults: defaults).pendingItems
        let expectedPendingDomains = Set(AccountDeletionCleanupDomain.allCases)
            .subtracting([.milestones])
        XCTAssertEqual(pending.count, expectedPendingDomains.count)
        XCTAssertEqual(model.accountDeletionCleanupFailures.count, pending.count)
        XCTAssertEqual(model.accountDeletionCleanupStatus, .cleanupRequired)
        XCTAssertTrue(model.storageStatus.isDegraded)
        XCTAssertNil(cardCatalogCache.load(userID: user.id))
        XCTAssertNil(cardCatalogCache.loadManualDrafts(userID: user.id))
        XCTAssertFalse(model.shouldShowAccountDeletionCleanupWarning)
        XCTAssertTrue(expectedPendingDomains.allSatisfy { domain in
            pending.contains { $0.userID == user.id && $0.domain == domain }
        })
        XCTAssertFalse(pending.contains { $0.domain == .milestones })
        await model.retryAccountDeletionCleanup()
        XCTAssertEqual(model.accountDeletionCleanupStatus, .cleanupRequired)
        XCTAssertEqual(model.accountDeletionCleanupFailures.count, pending.count)
    }

    func testRejectedAccountDeletionDoesNotScheduleCleanup() async throws {
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
        }
        let defaults = try makeDefaults()
        // A prior deleted account can retain cleanup without surfacing its status
        // to a different authenticated account on the same device.
        AccountDeletionCleanupLedger(defaults: defaults).schedule(userID: 99)
        let user = CurrentUser(
            id: 42,
            name: "Current User",
            email: "current@example.com",
            emailVerifiedAt: nil
        )
        let credentials = CleanupCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let authClient = makeClient { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                return Self.response(data: Data(
                    #"{"data":{"id":42,"name":"Current User","email":"current@example.com","email_verified_at":null}}"#.utf8
                ))
            case ("/api/me", "DELETE"):
                return Self.response(
                    statusCode: 422,
                    data: Data(#"{"message":"The current password is incorrect."}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        let model = AppModel(
            configuration: AppConfiguration(
                apiBaseURL: URL(string: "https://example.test")!
            ),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            },
            makeAuthStore: { _ in
                AuthStore(api: authClient, keychain: credentials)
            },
            accountDeletionCleanupDefaults: defaults
        )
        await model.auth.restore()

        XCTAssertEqual(model.accountDeletionCleanupStatus, .cleanupRequired)
        XCTAssertFalse(model.shouldShowAccountDeletionCleanupWarning)

        let deleted = await model.deleteAccount(currentPassword: "wrong-password")
        XCTAssertFalse(deleted)
        let pending = AccountDeletionCleanupLedger(defaults: defaults).pendingItems
        XCTAssertTrue(pending.allSatisfy { $0.userID == 99 })
        guard case let .signedIn(currentUser) = model.auth.state else {
            return XCTFail("Rejected deletion must preserve the authenticated account")
        }
        XCTAssertEqual(currentUser.id, user.id)
    }

    func testStaleDeletionDoesNotRestoreDeletedUsersInterruptedStudyTime() async throws {
        defer {
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
        }
        let defaults = try makeDefaults()
        let originalUser = CurrentUser(
            id: 42,
            name: "Deleted User",
            email: "deleted@example.com",
            emailVerifiedAt: nil
        )
        let credentials = CleanupCredentialStore(values: [
            "learning-os-mobile-token": "old-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(originalUser),
                encoding: .utf8
            )!,
        ])
        let deferredDeletion = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"data":{"id":42,"name":"Deleted User","email":"deleted@example.com","email_verified_at":null}}"#.utf8
                ))))
            case ("/api/me", "DELETE"):
                deferredDeletion.hold(completion)
            case ("/api/auth/tokens/current", "DELETE"):
                completion(.success(Self.response(statusCode: 204)))
            case ("/api/convolab/auth/register", "POST"):
                completion(.success(Self.response(statusCode: 201, data: Data(
                    #"{"data":{"user":{"id":84,"name":"New User","email":"new@example.com","email_verified_at":null},"token":"new-token"}}"#.utf8
                ))))
            case ("/api/study/activity-sessions/batch", "POST"):
                completion(.success(Self.response(data: Data("[]".utf8))))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                completion(.failure(URLError(.badURL)))
            }
        }
        let model = AppModel(
            configuration: AppConfiguration(
                apiBaseURL: URL(string: "https://example.test")!
            ),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            },
            makeAPIClient: { _ in client },
            makeAuthStore: { _ in
                AuthStore(api: client, keychain: credentials)
            },
            accountDeletionCleanupDefaults: defaults
        )
        await model.auth.restore()
        model.studyTime.activate(userID: originalUser.id)
        model.studyTime.start(
            activity: .reading,
            source: .manual,
            name: "Deleted user's reading"
        )

        let deletion = Task {
            await model.deleteAccount(currentPassword: "password")
        }
        await deferredDeletion.waitUntilPending()
        await model.auth.logout()
        await model.auth.register(
            name: "New User",
            email: "new@example.com",
            password: "password123",
            inviteCode: "INVITE1"
        )
        model.studyTime.activate(userID: 84)
        model.studyTime.start(
            activity: .podcast,
            source: .manual,
            name: "New user's listening"
        )
        deferredDeletion.succeed(with: Self.response(statusCode: 204))

        let deleted = await deletion.value
        XCTAssertFalse(deleted)
        guard case let .signedIn(currentUser) = model.auth.state else {
            return XCTFail("New user must remain signed in")
        }
        XCTAssertEqual(currentUser.id, 84)
        XCTAssertEqual(model.studyTime.active?.name, "New user's listening")
        XCTAssertTrue(
            AccountDeletionCleanupLedger(defaults: defaults).pendingItems.isEmpty
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "AccountDeletionCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func fallbackOnly(
        _ factory: @escaping (Bool) throws -> ModelContainer
    ) -> (Bool) throws -> ModelContainer {
        { inMemory in
            guard inMemory else { throw CleanupContainerFailure.unavailable }
            return try factory(true)
        }
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

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private nonisolated static func response(
        statusCode: Int = 200,
        data: Data = Data()
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://example.test")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    private func insertCard(userID: Int, into container: ModelContainer) throws {
        let card = StudyCard(
            id: "deleted-user-card",
            syncId: nil,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["expression": .string("削除")]),
            answer: .object(["meaning": .string("delete")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: nil,
            createdAt: .now,
            updatedAt: .now
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: userID,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
    }

    private func studyTimeSession() -> StudyActivitySession {
        StudyActivitySession(
            id: "server-session",
            clientSessionId: "018f22d2-6d38-7000-8000-000000000099",
            category: .immerse,
            activity: .reading,
            source: .manual,
            name: "Reading",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_300),
            durationMs: 300_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
    }
}

private enum CleanupContainerFailure: Error {
    case unavailable
}

@MainActor
private final class CleanupProbe {
    private let failing: Set<AccountDeletionCleanupDomain>
    private(set) var attempted: [AccountDeletionCleanupDomain] = []
    private(set) var attemptedUserIDs: [Int] = []

    init(failing: Set<AccountDeletionCleanupDomain> = []) {
        self.failing = failing
    }

    var operations: [
        AccountDeletionCleanupDomain: AccountDeletionCleanupCoordinator.CleanupOperation
    ] {
        Dictionary(
            uniqueKeysWithValues: AccountDeletionCleanupDomain.allCases.map { domain in
                (domain, { [weak self] userID in
                    guard let self else { return false }
                    attempted.append(domain)
                    attemptedUserIDs.append(userID)
                    return !failing.contains(domain)
                })
            }
        )
    }
}

@MainActor
private final class EmptyCredentialStore: CredentialStore {
    func save(_: String, account _: String) throws {}
    func read(account _: String) throws -> String? { nil }
    func remove(account _: String) throws {}
}

@MainActor
private final class CleanupCredentialStore: CredentialStore {
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

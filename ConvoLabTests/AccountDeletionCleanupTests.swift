import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AccountDeletionCleanupTests: XCTestCase {
    // The iOS 26 XCTest runtime can double-free closure-backed fixture teardown
    // state. Retain these short-lived probes until the test process exits.
    private nonisolated(unsafe) static var retainedFixtures: [AnyObject] = []

    func testCleanupAttemptsEveryDomainAndRetainsEveryFailure() throws {
        let defaults = try makeDefaults()
        let ledger = AccountDeletionCleanupLedger(defaults: defaults)
        let probe = CleanupProbe(failing: [.study, .studyTime])
        let coordinator = AccountDeletionCleanupCoordinator(
            ledger: ledger,
            operations: probe.operations
        )
        coordinator.scheduleCleanup(userID: 42)

        let failures = coordinator.retryPendingCleanup()

        XCTAssertEqual(probe.attempted.count, 4)
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

    func testRelaunchRetriesOnlyDurablyPendingCleanupDomains() throws {
        let defaults = try makeDefaults()
        let firstLedger = AccountDeletionCleanupLedger(defaults: defaults)
        let firstProbe = CleanupProbe(failing: [.study, .studyTime])
        let firstCoordinator = AccountDeletionCleanupCoordinator(
            ledger: firstLedger,
            operations: firstProbe.operations
        )
        firstCoordinator.scheduleCleanup(userID: 42)
        XCTAssertEqual(firstCoordinator.retryPendingCleanup().count, 2)

        let relaunchedProbe = CleanupProbe()
        let relaunchedLedger = AccountDeletionCleanupLedger(defaults: defaults)
        let relaunchedCoordinator = AccountDeletionCleanupCoordinator(
            ledger: relaunchedLedger,
            operations: relaunchedProbe.operations
        )

        XCTAssertTrue(relaunchedCoordinator.retryPendingCleanup().isEmpty)
        XCTAssertEqual(relaunchedProbe.attempted.count, 2)
        XCTAssertTrue(relaunchedProbe.attempted.contains(.study))
        XCTAssertTrue(relaunchedProbe.attempted.contains(.studyTime))
        XCTAssertTrue(relaunchedLedger.pendingItems.isEmpty)
        Self.retainedFixtures.append(firstProbe)
        Self.retainedFixtures.append(firstCoordinator)
        Self.retainedFixtures.append(relaunchedProbe)
        Self.retainedFixtures.append(relaunchedCoordinator)
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
    }

    func testConfirmedAccountDeletionSchedulesEveryCleanupBeforeFailedAttempts() async throws {
        let defaults = try makeDefaults()
        let user = CurrentUser(
            id: 42,
            name: "Deleted User",
            email: "deleted@example.com",
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
        XCTAssertEqual(pending.count, AccountDeletionCleanupDomain.allCases.count)
        XCTAssertEqual(model.accountDeletionCleanupFailures.count, pending.count)
        XCTAssertTrue(AccountDeletionCleanupDomain.allCases.allSatisfy { domain in
            pending.contains { $0.userID == user.id && $0.domain == domain }
        })
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

    init(failing: Set<AccountDeletionCleanupDomain> = []) {
        self.failing = failing
    }

    var operations: [
        AccountDeletionCleanupDomain: AccountDeletionCleanupCoordinator.CleanupOperation
    ] {
        Dictionary(
            uniqueKeysWithValues: AccountDeletionCleanupDomain.allCases.map { domain in
                (domain, { [weak self] (_: Int) in
                    guard let self else { return false }
                    attempted.append(domain)
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

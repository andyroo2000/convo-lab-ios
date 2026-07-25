import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AccountIsolationTests: XCTestCase {
    private nonisolated(unsafe) static var retainedObservableStores: [AnyObject] = []

    func testStudyStoreOnlyLoadsTheActiveUsersCards() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        try insertCard(id: "user-one-card", userID: 1, into: container)
        try insertCard(id: "user-two-card", userID: 2, into: container)
        let client = makeClient()
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activate(userID: 1)
        XCTAssertEqual(store.cards.map(\.id), ["user-one-card"])

        store.activate(userID: 2)
        XCTAssertEqual(store.cards.map(\.id), ["user-two-card"])

        store.deactivate()
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        // Observation's iOS 26 simulator runtime can double-free task-local
        // teardown state when a switched @Observable is released inside XCTest.
        Self.retainedObservableStores.append(store)
    }

    func testDailyAudioStoreOnlyLoadsTheActiveUsersPractices() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        try insertPractice(id: "practice-one", userID: 1, into: container)
        try insertPractice(id: "practice-two", userID: 2, into: container)
        let client = makeClient()
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = DailyAudioStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activate(userID: 1)
        XCTAssertEqual(store.practices.map(\.id), ["practice-one"])

        store.activate(userID: 2)
        XCTAssertEqual(store.practices.map(\.id), ["practice-two"])

        store.deactivate()
        XCTAssertTrue(store.practices.isEmpty)
        Self.retainedObservableStores.append(store)
    }

    func testMediaCacheSeparatesAndClearsDownloadsByUser() async throws {
        let requestCounter = AccountIsolationCounter()
        let client = makeClient { request in
            let version = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio-\(version)".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/shared")!

        cache.activate(userID: 1)
        let userOneURL = try await cache.download(remoteURL, category: "active-study")

        cache.activate(userID: 2)
        XCTAssertNil(cache.localURL(for: remoteURL))
        let userTwoURL = try await cache.download(remoteURL, category: "active-study")

        XCTAssertNotEqual(userOneURL, userTwoURL)
        XCTAssertEqual(requestCounter.current, 2)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            2
        )

        try cache.clearDownloadedMedia()
        XCTAssertNil(cache.localURL(for: remoteURL))

        cache.activate(userID: 1)
        XCTAssertEqual(cache.localURL(for: remoteURL), userOneURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userOneURL.path))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    private func insertCard(
        id: String,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let card = StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: .now,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let payload = try StorageCodec.encoder.encode(card)
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: userID,
                queueIndex: 0,
                payload: payload
            )
        )
        try container.mainContext.save()
    }

    private func insertPractice(
        id: String,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let practice = DailyAudioPractice(
            id: id,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: []
        )
        container.mainContext.insert(
            LocalDailyAudioPractice(
                practice: practice,
                userID: userID,
                payload: try StorageCodec.encoder.encode(practice)
            )
        )
        try container.mainContext.save()
    }

    private func makeClient(
        handler: @escaping MockURLProtocol.Handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("{}".utf8)
            )
        }
    ) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private final class AccountIsolationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.withLock { value }
    }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

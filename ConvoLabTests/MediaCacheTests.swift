import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class MediaCacheTests: XCTestCase {
    @MainActor
    func testChangingSignatureReusesStableMediaCacheEntry() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)

        let first = try await cache.download(
            URL(string: "https://cdn.example/audio/track.mp3?signature=first&expires=1")!,
            category: "daily-audio"
        )
        let second = try await cache.download(
            URL(string: "https://cdn.example/audio/track.mp3?signature=second&expires=2")!,
            category: "daily-audio"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(requestCounter.current, 1)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    @MainActor
    func testRefreshReplacesExistingBytesForStableMediaURL() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/answer")!

        let first = try await cache.download(remoteURL, category: "active-study")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "audio-1")

        let refreshed = try await cache.refresh(remoteURL, category: "active-study")

        XCTAssertEqual(first, refreshed)
        XCTAssertEqual(try String(contentsOf: refreshed, encoding: .utf8), "audio-2")
        XCTAssertEqual(requestCounter.current, 2)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    @MainActor
    func testFailedRefreshKeepsPreviouslyCachedAudioPlayable() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            guard requestCounter.next() == 1 else {
                throw URLError(.notConnectedToInternet)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("original-audio".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/answer")!
        let original = try await cache.download(remoteURL, category: "active-study")

        do {
            _ = try await cache.refresh(remoteURL, category: "active-study")
            XCTFail("Expected refresh to fail")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            try String(contentsOf: original, encoding: .utf8),
            "original-audio"
        )
        XCTAssertEqual(cache.localURL(for: remoteURL), original)
    }

    @MainActor
    func testOrdinaryDownloadJoinsForcedRefreshInsteadOfReturningStaleFile() async throws {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("old-audio".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/answer")!
        _ = try await cache.download(remoteURL, category: "active-study")

        let gate = LockedRequestGate()
        let refreshRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = refreshRequests.next()
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("fresh-audio".utf8)
            )
        }
        let refresh = Task {
            try await cache.refresh(remoteURL, category: "active-study")
        }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completion = MediaDownloadCompletion()
        let ordinaryDownload = Task {
            let url = try await cache.download(remoteURL, category: "active-study")
            await completion.markCompleted()
            return url
        }
        try await Task.sleep(for: .milliseconds(25))

        let completedBeforeRefresh = await completion.isCompleted
        XCTAssertFalse(completedBeforeRefresh)
        gate.release()
        let refreshedURL = try await refresh.value
        let ordinaryURL = try await ordinaryDownload.value

        XCTAssertEqual(ordinaryURL, refreshedURL)
        XCTAssertEqual(refreshRequests.current, 1)
        XCTAssertEqual(
            try String(contentsOf: ordinaryURL, encoding: .utf8),
            "fresh-audio"
        )
    }

    @MainActor
    func testReadinessSnapshotDoesNotUpdateMediaAccessTime() async throws {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "https://cdn.example/audio/track.mp3")!
        _ = try await cache.download(remoteURL, category: "active-study")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<CachedMediaRecord>()).first
        )
        let previousAccess = Date(timeIntervalSince1970: 1_000)
        record.lastAccessedAt = previousAccess
        try container.mainContext.save()

        let available = cache.cachedKeys(for: [remoteURL])

        XCTAssertEqual(available, [MediaCache.stableCacheKey(for: remoteURL)])
        XCTAssertEqual(record.lastAccessedAt, previousAccess)
    }
}

private actor MediaDownloadCompletion {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

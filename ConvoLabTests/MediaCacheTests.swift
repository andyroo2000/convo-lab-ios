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

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

import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class DailyAudioStoreTests: XCTestCase {
    func testListAndCreateDecodeDirectLearningOSCompatibilityPayloads() async throws {
        let practiceJSON = #"""
        {
          "id": "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
          "practiceDate": "2026-07-23",
          "status": "generating",
          "targetDurationMinutes": 30,
          "errorMessage": null,
          "createdAt": "2026-07-23T12:00:00.000Z",
          "updatedAt": "2026-07-23T12:00:00.000Z",
          "tracks": [{
            "id": "4aa076b2-1bc7-45a8-b7b4-12b74dcbd463",
            "practiceId": "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
            "mode": "drill",
            "status": "draft",
            "title": "Recognition drill",
            "sortOrder": 0,
            "audioUrl": null,
            "approxDurationSeconds": null,
            "updatedAt": "2026-07-23T12:00:00.000Z"
          }]
        }
        """#
        let client = makeClient { request in
            let body = request.httpMethod == "GET"
                ? Data("[\(practiceJSON)]".utf8)
                : Data(practiceJSON.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: request.httpMethod == "GET" ? 200 : 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = DailyAudioStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.refresh()
        XCTAssertEqual(store.practices.map(\.id), ["39ac4e14-b8b0-482c-8831-a3c1cb1987e9"])

        await store.create()
        XCTAssertEqual(store.practices.count, 1)
        XCTAssertEqual(store.practices.first?.tracks.first?.mode, "drill")
        XCTAssertNil(store.errorMessage)
    }

    func testRegeneratedTrackWithSameIDAndURLDownloadsItsNewRevision() async throws {
        let requestCounter = LockedCounter()
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
        let store = DailyAudioStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        let first = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1_000))
        let regenerated = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))

        let firstResolvedURL = await store.playableURL(for: first)
        let regeneratedResolvedURL = await store.playableURL(for: regenerated)
        let firstURL = try XCTUnwrap(firstResolvedURL)
        let regeneratedURL = try XCTUnwrap(regeneratedResolvedURL)

        XCTAssertNotEqual(firstURL, regeneratedURL)
        XCTAssertEqual(
            try String(contentsOf: regeneratedURL, encoding: .utf8),
            "audio-2"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let cachedRecords = try container.mainContext.fetch(
            FetchDescriptor<CachedMediaRecord>()
        )
        XCTAssertEqual(cachedRecords.count, 2)
        XCTAssertEqual(
            cachedRecords.first {
                $0.remoteURL.hasSuffix(":1000000")
            }?.category,
            "deferred-deletion"
        )
        XCTAssertEqual(
            cachedRecords.first {
                $0.remoteURL.hasSuffix(":2000000")
            }?.category,
            "daily-audio"
        )
        XCTAssertEqual(requestCounter.current, 2)
    }

    func testDownloadingVersionedTrackRetiresLegacyUnversionedCacheEntry() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("new-audio".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = DailyAudioStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        let track = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))
        let legacyKey = "daily-audio:\(track.id)"
        container.mainContext.insert(
            CachedMediaRecord(
                remoteURL: legacyKey,
                relativePath: "legacy.mp3",
                byteCount: 10,
                category: "daily-audio"
            )
        )
        try container.mainContext.save()

        let playableURL = await store.playableURL(for: track)

        XCTAssertNotNil(playableURL)
        let records = try container.mainContext.fetch(
            FetchDescriptor<CachedMediaRecord>()
        )
        XCTAssertEqual(
            records.first { $0.remoteURL == legacyKey }?.category,
            "deferred-deletion"
        )
    }

    private func dailyAudioTrack(updatedAt: Date) -> DailyAudioTrack {
        DailyAudioTrack(
            id: "4aa076b2-1bc7-45a8-b7b4-12b74dcbd463",
            practiceId: "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
            mode: "drill",
            status: "ready",
            title: "Recognition drill",
            sortOrder: 0,
            audioUrl: "/api/daily-audio-practice/practice/tracks/track/audio",
            approxDurationSeconds: 60,
            updatedAt: updatedAt
        )
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

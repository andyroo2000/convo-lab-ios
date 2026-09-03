import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension DailyAudioStoreTests {
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
        let first = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1_000))
        try insertPractice(containing: first, userID: 1, into: container)
        let store = makeStore(client: client, container: container)
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
        let track = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))
        try insertPractice(containing: track, userID: 1, into: container)
        let store = makeStore(client: client, container: container)
        let legacyKey = "daily-audio:\(track.id)"
        container.mainContext.insert(
            CachedMediaRecord(
                remoteURL: legacyKey,
                userID: 1,
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

    func testPracticeDownloadReportsActivityThenResetsAsDownloaded() async throws {
        let practice = twoTrackPractice()
        let firstTrack = try XCTUnwrap(practice.tracks.first)
        let secondTrack = try XCTUnwrap(practice.tracks.last)
        let firstDownloadStarted = LockedCounter()
        let allowFirstDownload = DispatchSemaphore(value: 0)
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            if requestCounter.next() == 1 {
                _ = firstDownloadStarted.next()
                allowFirstDownload.wait()
            }
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
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
        let store = makeStore(client: client, container: container)

        let download = Task { await store.download(practice) }
        while firstDownloadStarted.current == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(store.isDownloading(firstTrack))
        XCTAssertFalse(store.isDownloaded(firstTrack))
        XCTAssertEqual(store.practiceDownloadProgress[practice.id], 0)
        XCTAssertTrue(store.isPracticeDownloadInProgress)

        let duplicateDownload = Task { await store.download(practice) }
        await duplicateDownload.value
        XCTAssertTrue(store.isDownloading(firstTrack))
        XCTAssertEqual(store.practiceDownloadProgress[practice.id], 0)

        allowFirstDownload.signal()
        await download.value

        XCTAssertFalse(store.isDownloading(firstTrack))
        XCTAssertNil(store.practiceDownloadProgress[practice.id])
        XCTAssertFalse(store.isPracticeDownloadInProgress)
        XCTAssertTrue(store.isDownloaded(firstTrack))
        XCTAssertTrue(store.isDownloaded(secondTrack))
        XCTAssertTrue(store.isDownloaded(practice))
        XCTAssertEqual(requestCounter.current, 2)

        await store.download(practice)
        XCTAssertEqual(requestCounter.current, 2)
    }

    private func twoTrackPractice() -> DailyAudioPractice {
        let firstTrack = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))
        let secondTrack = DailyAudioTrack(
            id: "4aa076b2-1bc7-45a8-b7b4-12b74dcbd464",
            practiceId: firstTrack.practiceId,
            mode: "dialogue",
            status: "ready",
            title: "Dialogue",
            sortOrder: 1,
            audioUrl: "/api/daily-audio-practice/practice/tracks/dialogue/audio",
            approxDurationSeconds: 90,
            updatedAt: firstTrack.updatedAt
        )
        return DailyAudioPractice(
            id: firstTrack.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [firstTrack, secondTrack]
        )
    }

}

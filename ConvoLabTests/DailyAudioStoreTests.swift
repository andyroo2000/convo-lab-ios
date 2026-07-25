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
        let first = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1_000))
        try insertPractice(containing: first, userID: 1, into: container)
        let store = DailyAudioStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
        let store = DailyAudioStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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

    func testOpeningPlayerLoadsAndPersistsDetailedTranscript() async throws {
        let summaryTrack = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))
        let detailedTrack = DailyAudioTrack(
            id: summaryTrack.id,
            practiceId: summaryTrack.practiceId,
            mode: summaryTrack.mode,
            status: summaryTrack.status,
            title: summaryTrack.title,
            sortOrder: summaryTrack.sortOrder,
            scriptUnitsJson: [
                DailyAudioScriptUnit(
                    type: "L2",
                    text: "猫です",
                    reading: "猫[ねこ]です",
                    translation: "It is a cat."
                ),
            ],
            audioUrl: summaryTrack.audioUrl,
            timingData: [
                DailyAudioTiming(unitIndex: 0, startTime: 0, endTime: 1_500),
            ],
            approxDurationSeconds: 1.5,
            updatedAt: summaryTrack.updatedAt
        )
        let detailedPractice = DailyAudioPractice(
            id: detailedTrack.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [detailedTrack]
        )
        let summaryPractice = DailyAudioPractice(
            id: summaryTrack.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: detailedPractice.createdAt,
            updatedAt: detailedPractice.updatedAt,
            tracks: [summaryTrack]
        )
        let expectedPath = "/api/daily-audio-practice/\(summaryTrack.practiceId)"
        let detailedData = try StorageCodec.encoder.encode(detailedPractice)
        let summaryData = try StorageCodec.encoder.encode([summaryPractice])
        let client = makeClient { request in
            let path = request.url?.path
            XCTAssertTrue(path == expectedPath || path == "/api/daily-audio-practice")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                path == expectedPath ? detailedData : summaryData
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        try insertPractice(containing: summaryTrack, userID: 1, into: container)
        let store = DailyAudioStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        let result = await store.detailedTrack(for: summaryTrack)

        XCTAssertEqual(result?.scriptUnitsJson?.first?.text, "猫です")
        XCTAssertEqual(result?.timingData?.first?.endTime, 1_500)
        await store.refresh()
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let cachedResult = await store.detailedTrack(for: summaryTrack)
        XCTAssertEqual(cachedResult?.scriptUnitsJson?.first?.text, "猫です")
        let record = try XCTUnwrap(
            container.mainContext.fetch(
                FetchDescriptor<LocalDailyAudioPractice>()
            ).first
        )
        let persisted = try StorageCodec.decoder.decode(
            DailyAudioPractice.self,
            from: record.payload
        )
        XCTAssertEqual(persisted.tracks.first?.scriptUnitsJson?.first?.translation, "It is a cat.")
    }

    func testTranscriptSelectsOnlyTheCurrentlySpokenTargetLanguageUnit() {
        let track = transcriptTrack(
            timings: [
                DailyAudioTiming(unitIndex: 0, startTime: 0, endTime: 1_000),
                DailyAudioTiming(unitIndex: 1, startTime: 1_000, endTime: 2_000),
            ]
        )

        XCTAssertNil(
            DailyAudioTranscript.currentSpokenUnit(
                in: track,
                elapsedSeconds: 0.5,
                durationSeconds: 2
            )
        )
        XCTAssertEqual(
            DailyAudioTranscript.currentSpokenUnit(
                in: track,
                elapsedSeconds: 1.25,
                durationSeconds: 2
            )?.text,
            "猫です"
        )
    }

    func testTranscriptTimingScalesToTheActualPlayerDuration() {
        let track = transcriptTrack(
            timings: [
                DailyAudioTiming(unitIndex: 1, startTime: 2_000, endTime: 4_000),
            ]
        )

        XCTAssertEqual(
            DailyAudioTranscript.currentSpokenUnit(
                in: track,
                elapsedSeconds: 1.5,
                durationSeconds: 2
            )?.text,
            "猫です"
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

    private func transcriptTrack(timings: [DailyAudioTiming]) -> DailyAudioTrack {
        DailyAudioTrack(
            id: "track",
            practiceId: "practice",
            mode: "drill",
            status: "ready",
            title: "Recognition drill",
            sortOrder: 0,
            scriptUnitsJson: [
                DailyAudioScriptUnit(
                    type: "narration_L1",
                    text: "Listen carefully.",
                    reading: nil,
                    translation: nil
                ),
                DailyAudioScriptUnit(
                    type: "L2",
                    text: "猫です",
                    reading: "猫[ねこ]です",
                    translation: "It is a cat."
                ),
            ],
            audioUrl: "/audio",
            timingData: timings,
            approxDurationSeconds: 2,
            updatedAt: .now
        )
    }

    private func insertPractice(
        containing track: DailyAudioTrack,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let practice = DailyAudioPractice(
            id: track.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [track]
        )
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: userID,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
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

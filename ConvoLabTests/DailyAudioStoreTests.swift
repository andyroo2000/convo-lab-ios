import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class DailyAudioStoreTests: XCTestCase {
    func testInterruptedOrStaleGenerationCanBeRetried() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = dailyAudioPractice(
            status: "generating",
            updatedAt: now.addingTimeInterval(-60)
        )
        let stale = dailyAudioPractice(
            status: "generating",
            updatedAt: now.addingTimeInterval(-(90 * 60))
        )
        let interruptedRegeneration = dailyAudioPractice(
            status: "ready",
            updatedAt: now
        )

        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                recent,
                startRequestWasInterrupted: true,
                relativeTo: now
            )
        )
        XCTAssertFalse(
            DailyAudioView.canRetryGeneration(
                recent,
                startRequestWasInterrupted: false,
                relativeTo: now
            )
        )
        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                stale,
                startRequestWasInterrupted: false,
                relativeTo: now
            )
        )
        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                interruptedRegeneration,
                startRequestWasInterrupted: true,
                relativeTo: now
            )
        )
    }

    func testCancelledCreateOffersAnActionableRetry() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        await store.create()

        XCTAssertTrue(store.generationStartWasInterrupted)
        XCTAssertEqual(
            store.errorMessage,
            "Generation was interrupted. You can retry it."
        )
        XCTAssertFalse(store.isLoading)
    }

    func testCancelledRefreshDoesNotMarkHealthyGenerationForRetry() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let practice = dailyAudioPractice(
            status: "generating",
            updatedAt: .now
        )
        container.mainContext.insert(
            LocalDailyAudioPractice(
                practice: practice,
                userID: 1,
                payload: try StorageCodec.encoder.encode(practice)
            )
        )
        try container.mainContext.save()
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

        await store.refresh()

        XCTAssertFalse(store.generationStartWasInterrupted)
        XCTAssertEqual(
            store.errorMessage,
            "Refresh was interrupted. Audio generation continues on the server."
        )
        XCTAssertFalse(store.isLoading)
    }

    func testSilentRefreshSuppressesTimeoutErrors() async throws {
        let client = makeClient { _ in
            throw URLError(.timedOut)
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        let refreshed = await store.refresh(showsErrors: false)

        XCTAssertFalse(refreshed)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testSilentRefreshDoesNotClearADownloadError() async throws {
        let track = dailyAudioTrack(updatedAt: .now)
        let practice = DailyAudioPractice(
            id: track.practiceId,
            practiceDate: "2026-07-30",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [track]
        )
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain"]
                )!,
                Data()
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
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

        await store.download(practice)
        let downloadError = try XCTUnwrap(store.errorMessage)
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"items":[],"total":0,"limit":14,"nextCursor":null}"#.utf8)
            )
        }

        let refreshed = await store.refresh(showsErrors: false)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.errorMessage, downloadError)
    }

    func testRefreshIfNeededThrottlesRecentSuccessfulRefresh() async throws {
        let requestCount = LockedCounter()
        let client = makeClient { request in
            requestCount.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "items": [],
                      "total": 0,
                      "limit": 14,
                      "nextCursor": null
                    }
                    """.utf8
                )
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        await store.refreshIfNeeded(maxAge: .seconds(60))
        await store.refreshIfNeeded(maxAge: .seconds(60))

        XCTAssertEqual(requestCount.current, 1)

        await store.refreshIfNeeded(maxAge: .zero)

        XCTAssertEqual(requestCount.current, 2)
    }

    func testRelativePracticeDateNamesTodayAndNearbyDays() throws {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let referenceDate = try XCTUnwrap(formatter.date(from: "2026-07-28"))

        XCTAssertEqual(
            DailyAudioView.relativePracticeDate("2026-07-28", relativeTo: referenceDate),
            "Today"
        )
        XCTAssertEqual(
            DailyAudioView.relativePracticeDate("2026-07-27", relativeTo: referenceDate),
            "Yesterday"
        )
        XCTAssertEqual(
            DailyAudioView.relativePracticeDate("2026-07-26", relativeTo: referenceDate),
            "Two Days Ago"
        )
    }

    func testPaginatedListAndDirectCreateDecodeLearningOSCompatibilityPayloads() async throws {
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
            "approxDurationSeconds": 95,
            "updatedAt": "2026-07-23T12:00:00.000Z"
          }]
        }
        """#
        let client = makeClient { request in
            let body: Data
            if request.httpMethod == "GET" {
                let queryItems = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems
                XCTAssertEqual(queryItems?.first { $0.name == "paginated" }?.value, "1")
                XCTAssertEqual(queryItems?.first { $0.name == "cursor" }?.value, "0")
                XCTAssertEqual(queryItems?.first { $0.name == "limit" }?.value, "14")
                body = Data(
                    """
                    {
                      "items": [\(practiceJSON)],
                      "total": 1,
                      "limit": 14,
                      "nextCursor": null
                    }
                    """.utf8
                )
            } else {
                body = Data(practiceJSON.utf8)
            }
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
        XCTAssertEqual(store.total, 1)
        XCTAssertFalse(store.hasMore)

        await store.create()
        XCTAssertEqual(store.practices.count, 1)
        XCTAssertEqual(store.practices.first?.tracks.first?.mode, "drill")
        XCTAssertEqual(store.practices.first?.tracks.first?.formattedDuration, "1:35")
        XCTAssertNil(store.errorMessage)
    }

    func testLegacyRootArrayStillRefreshesUntilPaginationBackendIsDeployed() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/daily-audio-practice")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    [{
                      "id": "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
                      "practiceDate": "2026-07-25",
                      "status": "ready",
                      "targetDurationMinutes": 30,
                      "errorMessage": null,
                      "createdAt": "2026-07-25T12:00:00.000Z",
                      "updatedAt": "2026-07-25T12:00:00.000Z",
                      "tracks": []
                    }]
                    """.utf8
                )
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        await store.refresh()

        XCTAssertEqual(store.practices.count, 1)
        XCTAssertEqual(store.total, 1)
        XCTAssertFalse(store.hasMore)
        XCTAssertNil(store.errorMessage)
    }

    func testLoadMoreAppendsDistinctEarlierDailyAudioPages() async throws {
        let firstID = "39ac4e14-b8b0-482c-8831-a3c1cb1987e01"
        let secondID = "39ac4e14-b8b0-482c-8831-a3c1cb1987e02"
        let client = makeClient { request in
            let cursor = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first { $0.name == "cursor" }?.value
            let id = cursor == "0" ? firstID : secondID
            let date = cursor == "0" ? "2026-07-25" : "2026-07-24"
            let nextCursor = cursor == "0" ? #""1""# : "null"
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "items": [{
                        "id": "\(id)",
                        "practiceDate": "\(date)",
                        "status": "ready",
                        "targetDurationMinutes": 30,
                        "errorMessage": null,
                        "createdAt": "\(date)T12:00:00.000Z",
                        "updatedAt": "\(date)T12:00:00.000Z",
                        "tracks": []
                      }],
                      "total": 2,
                      "limit": 14,
                      "nextCursor": \(nextCursor)
                    }
                    """.utf8
                )
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        await store.refresh()
        await store.loadMore()

        XCTAssertEqual(store.practices.map(\.id), [firstID, secondID])
        XCTAssertEqual(store.total, 2)
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<LocalDailyAudioPractice>()).count,
            2
        )
    }

    func testCreatePreservesTheServerIssuedPaginationCursor() async throws {
        let firstPractice = """
        {
          "id": "39ac4e14-b8b0-482c-8831-a3c1cb1987e01",
          "practiceDate": "2026-07-24",
          "status": "ready",
          "targetDurationMinutes": 30,
          "errorMessage": null,
          "createdAt": "2026-07-24T12:00:00.000Z",
          "updatedAt": "2026-07-24T12:00:00.000Z",
          "tracks": []
        }
        """
        let createdPractice = """
        {
          "id": "39ac4e14-b8b0-482c-8831-a3c1cb1987e02",
          "practiceDate": "2026-07-25",
          "status": "generating",
          "targetDurationMinutes": 30,
          "errorMessage": null,
          "createdAt": "2026-07-25T12:00:00.000Z",
          "updatedAt": "2026-07-25T12:00:00.000Z",
          "tracks": []
        }
        """
        let client = makeClient { request in
            let body = if request.httpMethod == "POST" {
                Data(createdPractice.utf8)
            } else {
                Data(
                    """
                    {
                      "items": [\(firstPractice)],
                      "total": 20,
                      "limit": 14,
                      "nextCursor": "14"
                    }
                    """.utf8
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: request.httpMethod == "POST" ? 202 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        await store.refresh()
        await store.create()

        XCTAssertEqual(store.nextCursor, "14")
        XCTAssertEqual(store.total, 21)
        XCTAssertEqual(store.practices.count, 2)
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

    func testPracticeDownloadReportsActivityThenResetsAsDownloaded() async throws {
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
        let practice = DailyAudioPractice(
            id: firstTrack.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [firstTrack, secondTrack]
        )
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

        let download = Task { await store.download(practice) }
        while firstDownloadStarted.current == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(store.isDownloading(firstTrack))
        XCTAssertFalse(store.isDownloaded(firstTrack))
        XCTAssertEqual(store.practiceDownloadProgress[practice.id], 0)

        let duplicateDownload = Task { await store.download(practice) }
        await duplicateDownload.value
        XCTAssertTrue(store.isDownloading(firstTrack))
        XCTAssertEqual(store.practiceDownloadProgress[practice.id], 0)

        allowFirstDownload.signal()
        await download.value

        XCTAssertFalse(store.isDownloading(firstTrack))
        XCTAssertNil(store.practiceDownloadProgress[practice.id])
        XCTAssertTrue(store.isDownloaded(firstTrack))
        XCTAssertTrue(store.isDownloaded(secondTrack))
        XCTAssertTrue(store.isDownloaded(practice))
        XCTAssertEqual(requestCounter.current, 2)

        await store.download(practice)
        XCTAssertEqual(requestCounter.current, 2)
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

    private func dailyAudioPractice(
        status: String,
        updatedAt: Date
    ) -> DailyAudioPractice {
        DailyAudioPractice(
            id: "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
            practiceDate: "2026-07-30",
            status: status,
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            tracks: []
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

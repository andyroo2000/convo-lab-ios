import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension DailyAudioStoreTests {
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
        let practiceJSON = compatibilityPracticeJSON()
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
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
                )
                XCTAssertEqual(payload["targetDurationMinutes"] as? Int, 45)
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
        let store = makeStore(client: client, container: container)
        defer { store.deactivate() }

        await store.refresh()
        XCTAssertEqual(store.practices.map(\.id), ["39ac4e14-b8b0-482c-8831-a3c1cb1987e9"])
        XCTAssertEqual(store.total, 1)
        XCTAssertFalse(store.hasMore)

        await store.create(edition: .fortyFiveMinutes)
        XCTAssertEqual(store.practices.count, 1)
        XCTAssertEqual(store.practices.first?.tracks.first?.mode, "drill")
        XCTAssertEqual(store.practices.first?.tracks.first?.formattedDuration, "1:35")
        XCTAssertNil(store.errorMessage)
    }

    func testAutomaticDownloadReservesSlotBeforeManualDownloadCanStart() async throws {
        let practiceID = "39ac4e14-b8b0-482c-8831-a3c1cb1987e9"
        let trackID = "4aa076b2-1bc7-45a8-b7b4-12b74dcbd463"
        let manualPracticeID = "39ac4e14-b8b0-482c-8831-a3c1cb1987ea"
        let manualTrackID = "4aa076b2-1bc7-45a8-b7b4-12b74dcbd464"
        let oldDate = Date(timeIntervalSince1970: 2_000)
        let newDate = Date(timeIntervalSince1970: 3_000)
        let (generatingPractice, readyPractice) = automaticDownloadTransition(
            practiceID: practiceID, trackID: trackID, oldDate: oldDate, newDate: newDate
        )
        let readyTrack = try XCTUnwrap(readyPractice.tracks.first)
        let manualPractice = manualDownloadPractice(
            practiceID: manualPracticeID,
            trackID: manualTrackID,
            updatedAt: oldDate
        )
        let manualTrack = try XCTUnwrap(manualPractice.tracks.first)
        let responseData = try StorageCodec.encoder.encode(DailyAudioPracticePage(
            items: [readyPractice, manualPractice],
            total: 2,
            limit: 14,
            nextCursor: nil
        ))
        let automaticRequestCount = LockedCounter()
        let manualRequestCount = LockedCounter()
        let client = makeClient { request in
            if request.url?.path == "/api/daily-audio-practice" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    responseData
                )
            }
            if request.url?.path == "/api/daily-audio-practice/\(practiceID)/tracks/\(trackID)/audio" {
                _ = automaticRequestCount.next()
            } else {
                XCTAssertEqual(
                    request.url?.path,
                    "/api/daily-audio-practice/\(manualPracticeID)/tracks/\(manualTrackID)/audio"
                )
                _ = manualRequestCount.next()
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
        try persist([generatingPractice, manualPractice], in: container)
        let store = makeStore(client: client, container: container)
        defer { store.deactivate() }

        try await awaitAutomaticDownload(
            store, whileRequesting: manualPractice, readyTrack: readyTrack
        )

        assertAutomaticDownload(
            store, readyPractice: readyPractice, readyTrack: readyTrack, manualTrack: manualTrack
        )
        XCTAssertEqual(automaticRequestCount.current, 1)
        XCTAssertEqual(manualRequestCount.current, 0)
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
        let store = makeStore(client: client, container: container)
        defer { store.deactivate() }

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
        let store = makeStore(client: client, container: container)

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
        let store = makeStore(client: client, container: container)
        defer { store.deactivate() }

        await store.refresh()
        await store.create()

        XCTAssertEqual(store.nextCursor, "14")
        XCTAssertEqual(store.total, 21)
        XCTAssertEqual(store.practices.count, 2)
    }

    private func compatibilityPracticeJSON() -> String {
        #"""
        {
          "id": "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
          "practiceDate": "2026-07-23",
          "status": "generating",
          "targetDurationMinutes": 45,
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
    }

    private func automaticDownloadTransition(
        practiceID: String,
        trackID: String,
        oldDate: Date,
        newDate: Date
    ) -> (DailyAudioPractice, DailyAudioPractice) {
        let draftTrack = DailyAudioTrack(
            id: trackID,
            practiceId: practiceID,
            mode: "drill",
            status: "generating",
            title: "Drills",
            sortOrder: 0,
            audioUrl: nil,
            approxDurationSeconds: nil,
            updatedAt: oldDate
        )
        let readyTrack = DailyAudioTrack(
            id: trackID,
            practiceId: practiceID,
            mode: "drill",
            status: "ready",
            title: "Drills",
            sortOrder: 0,
            audioUrl: "/api/daily-audio-practice/\(practiceID)/tracks/\(trackID)/audio",
            approxDurationSeconds: 3_600,
            updatedAt: newDate
        )
        return (
            DailyAudioPractice(
                id: practiceID, practiceDate: "2026-08-25", status: "generating",
                targetDurationMinutes: 60, errorMessage: nil,
                createdAt: oldDate, updatedAt: oldDate, tracks: [draftTrack]
            ),
            DailyAudioPractice(
                id: practiceID, practiceDate: "2026-08-25", status: "ready",
                targetDurationMinutes: 60, errorMessage: nil,
                createdAt: oldDate, updatedAt: newDate, tracks: [readyTrack]
            )
        )
    }

    private func manualDownloadPractice(
        practiceID: String,
        trackID: String,
        updatedAt: Date
    ) -> DailyAudioPractice {
        let track = DailyAudioTrack(
            id: trackID,
            practiceId: practiceID,
            mode: "drill",
            status: "ready",
            title: "Earlier Drills",
            sortOrder: 0,
            audioUrl: "/api/daily-audio-practice/\(practiceID)/tracks/\(trackID)/audio",
            approxDurationSeconds: 1_800,
            updatedAt: updatedAt
        )
        return DailyAudioPractice(
            id: practiceID,
            practiceDate: "2026-08-24",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            tracks: [track]
        )
    }

    private func persist(
        _ practices: [DailyAudioPractice],
        in container: ModelContainer
    ) throws {
        for practice in practices {
            container.mainContext.insert(LocalDailyAudioPractice(
                practice: practice,
                userID: 1,
                payload: try StorageCodec.encoder.encode(practice)
            ))
        }
        try container.mainContext.save()
    }

    private func assertAutomaticDownload(
        _ store: DailyAudioStore,
        readyPractice: DailyAudioPractice,
        readyTrack: DailyAudioTrack,
        manualTrack: DailyAudioTrack
    ) {
        XCTAssertTrue(store.isDownloaded(readyTrack))
        XCTAssertTrue(store.isDownloaded(readyPractice))
        XCTAssertFalse(store.isDownloaded(manualTrack))
        XCTAssertNil(store.errorMessage)
    }

    private func awaitAutomaticDownload(
        _ store: DailyAudioStore,
        whileRequesting manualPractice: DailyAudioPractice,
        readyTrack: DailyAudioTrack
    ) async throws {
        let didRefresh = await store.refresh()
        XCTAssertTrue(didRefresh)
        XCTAssertTrue(store.isPracticeDownloadInProgress)
        await store.download(manualPractice)
        for _ in 0..<100 where !store.isDownloaded(readyTrack) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

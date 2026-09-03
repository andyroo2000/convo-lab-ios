import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension DailyAudioStoreTests {
    func testOpeningPlayerLoadsAndPersistsDetailedTranscript() async throws {
        let summaryTrack = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2_000))
        let (detailedPractice, summaryPractice) = transcriptPractices(for: summaryTrack)
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
        let store = makeStore(client: client, container: container)

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

    func testOlderTrackDetailResponseCannotReplaceNewerPracticeRefresh() async throws {
        let oldDate = Date(timeIntervalSince1970: 2_000)
        let newDate = Date(timeIntervalSince1970: 3_000)
        let summaryTrack = dailyAudioTrack(updatedAt: oldDate)
        let staleDetail = staleDetailPractice(for: summaryTrack, updatedAt: oldDate)
        let refreshedPractice = refreshedPractice(
            for: summaryTrack, createdAt: oldDate, updatedAt: newDate)
        let practiceID = summaryTrack.practiceId
        let detailData = try StorageCodec.encoder.encode(staleDetail)
        let refreshData = try StorageCodec.encoder.encode(DailyAudioPracticePage(
            items: [refreshedPractice], total: 1, limit: 14, nextCursor: nil
        ))
        let deferredDetail = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.url?.path == "/api/daily-audio-practice/\(practiceID)" {
                deferredDetail.hold(completion)
                return
            }
            completion(.success((
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                refreshData
            )))
        }
        let container = try Persistence.makeContainer(inMemory: true)
        try insertPractice(containing: summaryTrack, userID: 1, into: container)
        let store = makeStore(client: client, container: container)

        let detail = Task { await store.detailedTrack(for: summaryTrack) }
        for _ in 0..<100 where !deferredDetail.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredDetail.hasPendingResponse)
        let refreshed = await store.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.practices.first?.status, "failed")
        XCTAssertEqual(store.practices.first?.tracks.first?.title, "New title")
        deferredDetail.succeed(with: (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            detailData
        ))
        _ = await detail.value

        XCTAssertEqual(store.practices.first?.status, "failed")
        XCTAssertEqual(store.practices.first?.targetDurationMinutes, 45)
        XCTAssertEqual(store.practices.first?.tracks.first?.title, "New title")
        XCTAssertEqual(
            store.practices.first?.tracks.first?.scriptUnitsJson?.first?.text,
            "猫です"
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalDailyAudioPractice>()).first
        )
        let persisted = try StorageCodec.decoder.decode(
            DailyAudioPractice.self,
            from: record.payload
        )
        XCTAssertEqual(persisted.status, "failed")
        XCTAssertEqual(persisted.tracks.first?.title, "New title")
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

    func testPlayerViewResolvesARegeneratedTrackFromLiveStoreData() {
        let oldTrack = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let regeneratedTrack = dailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))
        let practice = DailyAudioPractice(
            id: regeneratedTrack.practiceId,
            practiceDate: "2026-07-30",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: regeneratedTrack.updatedAt,
            updatedAt: regeneratedTrack.updatedAt,
            tracks: [regeneratedTrack]
        )

        let resolved = DailyAudioTrack.latest(
            matching: oldTrack,
            in: [practice]
        )

        XCTAssertEqual(resolved.revisionMilliseconds, 2_000)
        XCTAssertEqual(
            DailyAudioPlaybackIdentity(track: resolved),
            DailyAudioPlaybackIdentity(track: regeneratedTrack)
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

    private func transcriptPractices(
        for summaryTrack: DailyAudioTrack
    ) -> (DailyAudioPractice, DailyAudioPractice) {
        let detailedTrack = DailyAudioTrack(
            id: summaryTrack.id,
            practiceId: summaryTrack.practiceId,
            mode: summaryTrack.mode,
            status: summaryTrack.status,
            title: summaryTrack.title,
            sortOrder: summaryTrack.sortOrder,
            scriptUnitsJson: [
                DailyAudioScriptUnit(
                    type: "L2", text: "猫です", reading: "猫[ねこ]です",
                    translation: "It is a cat."
                ),
            ],
            audioUrl: summaryTrack.audioUrl,
            timingData: [DailyAudioTiming(unitIndex: 0, startTime: 0, endTime: 1_500)],
            approxDurationSeconds: 1.5,
            updatedAt: summaryTrack.updatedAt
        )
        let detailedPractice = DailyAudioPractice(
            id: detailedTrack.practiceId, practiceDate: "2026-07-25", status: "ready",
            targetDurationMinutes: 30, errorMessage: nil, createdAt: .now, updatedAt: .now,
            tracks: [detailedTrack]
        )
        let summaryPractice = DailyAudioPractice(
            id: summaryTrack.practiceId, practiceDate: "2026-07-25", status: "ready",
            targetDurationMinutes: 30, errorMessage: nil,
            createdAt: detailedPractice.createdAt, updatedAt: detailedPractice.updatedAt,
            tracks: [summaryTrack]
        )
        return (detailedPractice, summaryPractice)
    }

    private func staleDetailPractice(
        for summaryTrack: DailyAudioTrack,
        updatedAt: Date
    ) -> DailyAudioPractice {
        let track = DailyAudioTrack(
            id: summaryTrack.id, practiceId: summaryTrack.practiceId,
            mode: summaryTrack.mode, status: summaryTrack.status, title: "Old title",
            sortOrder: summaryTrack.sortOrder,
            scriptUnitsJson: [
                DailyAudioScriptUnit(
                    type: "L2", text: "猫です", reading: "猫[ねこ]です",
                    translation: "It is a cat."
                ),
            ],
            audioUrl: summaryTrack.audioUrl,
            timingData: [DailyAudioTiming(unitIndex: 0, startTime: 0, endTime: 1_500)],
            approxDurationSeconds: summaryTrack.approxDurationSeconds,
            updatedAt: updatedAt
        )
        return DailyAudioPractice(
            id: summaryTrack.practiceId, practiceDate: "2026-07-25", status: "ready",
            targetDurationMinutes: 30, errorMessage: nil,
            createdAt: updatedAt, updatedAt: updatedAt, tracks: [track]
        )
    }

    private func refreshedPractice(
        for summaryTrack: DailyAudioTrack,
        createdAt: Date,
        updatedAt: Date
    ) -> DailyAudioPractice {
        let track = DailyAudioTrack(
            id: summaryTrack.id, practiceId: summaryTrack.practiceId,
            mode: summaryTrack.mode, status: summaryTrack.status, title: "New title",
            sortOrder: summaryTrack.sortOrder, audioUrl: summaryTrack.audioUrl,
            approxDurationSeconds: summaryTrack.approxDurationSeconds,
            updatedAt: createdAt
        )
        return DailyAudioPractice(
            id: summaryTrack.practiceId, practiceDate: "2026-07-25", status: "failed",
            targetDurationMinutes: 45, errorMessage: "New server status",
            createdAt: createdAt, updatedAt: updatedAt, tracks: [track]
        )
    }

}

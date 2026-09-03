import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension AccountIsolationTests {
    func testDailyAudioDownloadStopsWhenTheAccountChanges() async throws {
        let gate = AccountIsolationGate()
        let requestCounter = AccountIsolationCounter()
        let client = makeClient { request in
            _ = requestCounter.next()
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("old account audio".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let practice = makeDownloadPractice()
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = DailyAudioStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: cache
        )

        let download = Task { await store.download(practice) }
        for _ in 0..<100 where !gate.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await download.value

        XCTAssertTrue((1...practice.tracks.count).contains(requestCounter.current))
        XCTAssertEqual(
            try localRecordCount(CachedMediaRecord.self, userID: 2, in: container),
            0
        )
        XCTAssertTrue(store.downloadingTrackIDs.isEmpty)
        XCTAssertNil(store.practiceDownloadProgress[practice.id])
        Self.retainedObservableStores.append(store)
    }

    func testDeletingMediaWhileDownloadIsInFlightCannotResurrectIt() async throws {
        let gate = AccountIsolationGate()
        let client = makeClient { request in
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("late audio".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/late")!
        let download = Task {
            try await cache.download(remoteURL, category: "offline-study")
        }
        for _ in 0..<100 where !gate.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        try cache.deleteLocalData(userID: 1)
        gate.release()
        _ = try? await download.value

        XCTAssertNil(cache.localURL(for: remoteURL))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    private func makeDownloadPractice() -> DailyAudioPractice {
        let practiceID = "39ac4e14-b8b0-482c-8831-a3c1cb1987e9"
        let tracks = [0, 1].map { index in
            DailyAudioTrack(
                id: "4aa076b2-1bc7-45a8-b7b4-12b74dcbd46\(index)",
                practiceId: practiceID,
                mode: "drill",
                status: "ready",
                title: "Track \(index)",
                sortOrder: index,
                audioUrl: "/api/daily-audio-practice/\(practiceID)/tracks/\(index)/audio",
                approxDurationSeconds: 60,
                updatedAt: .now
            )
        }
        return DailyAudioPractice(
            id: practiceID,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: tracks
        )
    }
}

final class AccountIsolationCounter: @unchecked Sendable {
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

private final class AccountIsolationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.withLock { started }
    }

    func markStarted() {
        condition.withLock {
            started = true
            condition.broadcast()
        }
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

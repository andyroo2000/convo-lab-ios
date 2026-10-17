import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testAutomaticSyncUpdatesMetadataWithoutDownloadingStudyMedia() async throws {
        let scenario = try makeMediaPolicyScenario()
        defer { scenario.store.deactivate() }

        await scenario.store.synchronize()

        XCTAssertEqual(scenario.store.syncStatus, .idle)
        XCTAssertNotNil(scenario.store.lastSyncAt)
        XCTAssertEqual(scenario.store.cards.count, 1)
        XCTAssertEqual(scenario.store.libraryCards.count, 2)
        XCTAssertEqual(scenario.store.offlineReserveDays, 5)
        XCTAssertFalse(scenario.paths.values.contains("/api/study/media/batch"))
        XCTAssertEqual(scenario.cache.totalByteCount, 0)
        XCTAssertEqual(scenario.store.preparedCardCount, 0)
    }

    @MainActor
    func testExplicitOfflineDownloadPreparesActiveAndReserveMedia() async throws {
        let scenario = try makeMediaPolicyScenario()
        defer {
            try? scenario.cache.clearDownloadedMedia()
            scenario.store.deactivate()
        }

        await scenario.store.downloadOfflineStudy()

        XCTAssertEqual(scenario.store.syncStatus, .idle)
        XCTAssertEqual(scenario.paths.values.count { $0 == "/api/study/media/batch" }, 2)
        XCTAssertEqual(scenario.store.preparedCardCount, 2)
        XCTAssertGreaterThan(scenario.cache.totalByteCount, 0)
        let downloadedRequests = scenario.paths.values.count

        await scenario.store.synchronize()

        XCTAssertEqual(scenario.paths.values.dropFirst(downloadedRequests).count, 4)
        XCTAssertEqual(scenario.store.preparedCardCount, 2)
    }

    @MainActor
    func testOfflineDownloadFailureDoesNotClaimMediaIsPrepared() async throws {
        let scenario = try makeMediaPolicyScenario(mediaStatus: 429)
        defer { scenario.store.deactivate() }

        await scenario.store.downloadOfflineStudy()

        XCTAssertEqual(scenario.store.cards.count, 1)
        XCTAssertEqual(scenario.store.preparedCardCount, 0)
        XCTAssertEqual(scenario.cache.totalByteCount, 0)
        XCTAssertEqual(scenario.paths.values.count { $0 == "/api/study/media/batch" }, 2)
    }

    @MainActor
    func testCancelledSyncDoesNotStartLaterMetadataStages() async throws {
        let scenario = try makeMediaPolicyScenario()
        defer { scenario.store.deactivate() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await scenario.store.synchronize()
        }
        await task.value

        XCTAssertTrue(scenario.paths.values.isEmpty)
        XCTAssertEqual(scenario.store.syncStatus, .idle)
        XCTAssertNil(scenario.store.lastSyncAt)
    }

    private struct MediaPolicyScenario {
        let store: StudyStore
        let cache: MediaCache
        let paths: LockedRequestPaths
    }

    @MainActor
    private func makeMediaPolicyScenario(mediaStatus: Int = 200) throws -> MediaPolicyScenario {
        let active = makeCard(id: "active", expression: "音声",
                              mediaURL: "/api/study/media/\(ClientIdentifier.ulid())")
        let reserve = makeCard(id: "reserve", expression: "予備",
                               mediaURL: "/api/study/media/\(ClientIdentifier.ulid())",
                               dueAt: .now.addingTimeInterval(86_400))
        let session = try sessionResponseData(cards: [active])
        let reserveObject = try JSONSerialization.jsonObject(with: StorageCodec.encoder.encode(reserve))
        let reserveData = try JSONSerialization.data(withJSONObject: [
            "cards": [reserveObject], "reserveDays": 5,
            "generatedAt": ISO8601Milliseconds.string(from: .now),
            "horizonEndsAt": ISO8601Milliseconds.string(from: .now.addingTimeInterval(432_000)),
        ])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            return try Self.mediaPolicyResponse(request, session: session, reserve: reserveData,
                                                mediaStatus: mediaStatus)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1, api: client, context: container.mainContext,
                               mediaCache: cache)
        return MediaPolicyScenario(store: store, cache: cache, paths: paths)
    }

    private static func mediaPolicyResponse(
        _ request: URLRequest, session: Data, reserve: Data, mediaStatus: Int
    ) throws -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/api/sync/feed":
            return response(data: Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8))
        case "/api/study/known-kanji":
            return response(data: Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8))
        case "/api/study/session/start": return response(data: session)
        case "/api/study/offline-reserve": return response(data: reserve)
        case "/api/study/media/batch":
            let ids = try JSONDecoder().decode([String: [String]].self, from: requestBody(request))["ids"] ?? []
            let items = ids.map { ["id": $0, "mimeType": "audio/mpeg", "data": Data("audio".utf8).base64EncodedString()] }
            return response(statusCode: mediaStatus,
                            data: try JSONSerialization.data(withJSONObject: ["items": items]))
        default: throw URLError(.badURL)
        }
    }
}

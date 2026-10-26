import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testPileCatalogDecodesSnakeCaseAndClearsOnAccountChange() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/piles")
            return Self.response(data: Self.pileCatalogData)
        }
        client.setAccessToken("test-token")
        let store = makePileStore(container, client)
        await store.refreshPiles()
        XCTAssertEqual(store.piles.catalog?.piles.first?.title, "Genki II")
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, true)
        XCTAssertEqual(store.piles.catalog?.piles.first?.readyCount, 3)
        store.deactivate()
        XCTAssertNil(store.piles.catalog)
    }

    @MainActor
    func testChapterToggleSendsOnlyTheSwitchAndKeepsCanonicalPath() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let id = "01jzq4nny5xbnzw14q1g68b2yt"
        let client = makeClient { request in
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/study/piles/\(id)/chapters/\(id)")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Bool])
                XCTAssertEqual(body, ["is_active": false])
                return Self.response(data: Data("{}".utf8))
            }
            return Self.response(data: Self.pileCatalogData)
        }
        client.setAccessToken("test-token")
        let store = makePileStore(container, client)
        try await store.savePile(id: id.uppercased(), update: StudyPileUpdate(isActive: false), pileID: id.uppercased())
        XCTAssertNotNil(store.piles.catalog)
    }

    @MainActor
    func testPileSessionUsesChosenPileWithoutChangingUnifiedReviewRequest() async throws {
        let client = makeClient { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String])
            XCTAssertNotNil(body["time_zone"])
            if request.url?.path == "/api/study/lessons/start" {
                XCTAssertEqual(body["pileId"], "learn-soon")
            } else {
                XCTAssertNil(body["pileId"])
            }
            return Self.response(data: Data(#"{"overview":{"dueCount":0,"newCount":0,"reviewCount":0,"totalCards":0,"newCardsPerDay":20,"lessonBatchSize":5},"cards":[]}"#.utf8))
        }
        let service = StudySessionLoadingService(api: client)
        service.activate(userID: 1)
        let lesson = try await service.load(.pile("learn-soon"))
        XCTAssertNotNil(lesson)
        let reviews = try await service.load(.reviews)
        XCTAssertNotNil(reviews)
    }

    @MainActor
    func testCancelledPileRefreshDoesNotDisableTheCatalog() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.cancelled) }
        client.setAccessToken("test-token")
        let store = makePileStore(container, client)
        await store.refreshPiles()
        XCTAssertNil(store.piles.errorMessage)
        XCTAssertFalse(store.piles.isRefreshing)
    }

    @MainActor
    func testNonadvancingPileCursorFailsInsteadOfLooping() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.pileCatalogData) as? [String: Any])
            page["next_cursor"] = 0
            return Self.response(data: try JSONSerialization.data(withJSONObject: page))
        }
        client.setAccessToken("test-token")
        let store = makePileStore(container, client)
        await store.refreshPiles()
        XCTAssertNotNil(store.piles.errorMessage)
        XCTAssertNil(store.piles.catalog)
    }

    @MainActor
    func testPileSelectionClearsWhenLeavingLessonPresentation() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in Self.response(data: Self.pileCatalogData) }
        let store = makePileStore(container, client)
        XCTAssertTrue(store.beginLessonSessionPresentation(pileID: "learn-soon"))
        XCTAssertEqual(store.activePileID, "learn-soon")
        store.endLessonSessionPresentation()
        XCTAssertNil(store.activePileID)
        XCTAssertTrue(store.beginLessonSessionPresentation())
        XCTAssertNil(store.activePileID)
    }

    @MainActor
    private func makePileStore(_ container: ModelContainer, _ client: APIClient) -> StudyStore {
        StudyStore(initialUserID: 1, api: client, context: container.mainContext,
                   mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
    }

    private static let pileCatalogData = Data(#"{"piles":[{"id":"01jzq4nny5xbnzw14q1g68b2yt","title":"Genki II","position":1,"is_active":true,"source_reference":null,"new_count":20,"ready_count":3,"introduced_count":4,"chapters":[{"id":"01jzq4nny5xbnzw14q1g68b2yu","title":"Chapter 20","position":20,"is_active":true,"source_reference":null,"new_count":20,"ready_count":3,"introduced_count":4}]}],"uncategorized":{"new_count":0,"ready_count":0,"introduced_count":0},"learn_soon":{"new_count":0,"ready_count":0,"introduced_count":0},"next_cursor":null}"#.utf8)
}

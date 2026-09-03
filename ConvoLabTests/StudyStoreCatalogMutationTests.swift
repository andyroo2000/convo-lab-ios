import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRefreshPreservesPendingLocalCardCreation() async throws {
        let emptyPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [], limit: 20, nextCursor: nil))
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, emptyPage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.createCard(expression: "保留", reading: "ほりゅう", meaning: "pending")
        let optimisticItem = try XCTUnwrap(store.learningItems.first)

        try await store.refreshLearningItems()

        XCTAssertEqual(store.learningItems.map(\.id), [optimisticItem.id])
        XCTAssertEqual(store.learningItems.first?.representativeCard.displayText, "保留")
    }

    @MainActor
    func testRefreshReconcilesPendingLocalCardEditAndDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "pending-refresh-card", expression: "古い")
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [card], matching: "").first)
        let stalePage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil))
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, stalePage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.refreshLearningItems()
        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        try await store.refreshLearningItems()

        XCTAssertEqual(store.learningItems.first?.representativeCard.displayText, "新しい")
        let updatedCard = try XCTUnwrap(store.card(for: staleItem.representativeCard))
        try await store.deleteCard(updatedCard)

        try await store.refreshLearningItems()

        XCTAssertTrue(store.learningItems.isEmpty)
    }

    @MainActor
    func testClearingSearchDoesNotRestorePendingDeletedCardFromFreshSnapshot() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "pending-search-delete", expression: "古い")
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [card], matching: "").first)
        let stalePage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil))
        let learningItemRequests = LockedRequestPaths()
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                learningItemRequests.append(request.url?.absoluteString ?? "")
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, stalePage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.refreshLearningItems()
        let currentCard = try XCTUnwrap(store.card(for: staleItem.representativeCard))
        try await store.deleteCard(currentCard)
        XCTAssertTrue(store.learningItems.isEmpty)

        try await store.refreshLearningItems(search: "古")
        XCTAssertTrue(store.learningItems.isEmpty)

        try await store.refreshLearningItemsIfNeeded(search: "")

        XCTAssertTrue(store.learningItems.isEmpty)
        XCTAssertEqual(learningItemRequests.values.count, 2)
    }

    @MainActor
    func testClearingSearchOfflineWithoutSnapshotRestoresPagedLocalCards() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dog = makeCard(id: "local-dog", expression: "Dog")
        let cat = makeCard(id: "local-cat", expression: "Cat")
        for (index, card) in [dog, cat].enumerated() {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card, userID: 1, queueIndex: index, payload: try StorageCodec.encoder.encode(card)))
        }
        try container.mainContext.save()
        let dogItem = try XCTUnwrap(StudyCardCatalogRepository.standaloneLearningItems(from: [dog], matching: "").first)
        let dogPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [dogItem], limit: 20, nextCursor: nil))
        let client = makeClient { request in
            guard request.url?.query?.contains("q=Dog") == true else { throw URLError(.notConnectedToInternet) }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, dogPage
            )
        }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.refreshLearningItems(search: "Dog")

        do {
            try await store.refreshLearningItems(search: "")
            XCTFail("Expected the offline refresh to fail")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }

        XCTAssertEqual(store.learningItemsQuery, "")
        XCTAssertEqual(Set(store.learningItems.map(\.representativeCard.id)), Set([dog.id, cat.id]))
        Self.retainedObservableStores.append(store)
    }

    @MainActor
    func testSuccessfulSearchMutationsUpdateCachedDefaultItemsBeforeRelaunch() async throws {
        let suiteName = "StudyStoreCatalogTests.search-mutation-cache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "search-mutation-cache", expression: "古い")
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [card], matching: "").first)
        let refreshedAt = Date.now
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(
            StudyCardCatalogSnapshot(
                savedAt: refreshedAt, newCardQueue: [], newCardQueueTotal: 0, newCardQueueNextCursor: nil,
                newCardQueueRefreshedAt: refreshedAt, learningItems: [staleItem], learningItemsNextCursor: nil,
                learningItemsRefreshedAt: refreshedAt), userID: 1)
        let searchPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil))
        let updatedServerCard = makeCard(id: card.id, expression: "新しい")
        let updatedCardData = try StorageCodec.encoder.encode(updatedServerCard)
        let client = makeClient { request in
            let data: Data
            let statusCode: Int
            switch request.httpMethod {
            case "GET" where request.url?.path == "/api/study/learning-items":
                data = searchPage
                statusCode = 200
            case "PATCH":
                data = updatedCardData
                statusCode = 200
            case "DELETE":
                data = Data()
                statusCode = 204
            default:
                XCTFail("Unexpected request: " + "\(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: statusCode, httpVersion: nil,
                    headerFields: data.isEmpty ? nil : ["Content-Type": "application/json"])!, data
            )
        }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)
        try await store.refreshLearningItems(search: "古い")

        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty)
        XCTAssertEqual(cache.load(userID: 1)?.learningItems.first?.representativeCard.displayText, "新しい")

        try await store.deleteCard(card)

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty)
        XCTAssertTrue(cache.load(userID: 1)?.learningItems.isEmpty == true)
        store.deactivate()

        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let relaunchedStore = StudyStore(
            initialUserID: 1, api: offlineClient, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: offlineClient, context: container.mainContext),
            cardCatalogSnapshotCache: cache)

        XCTAssertTrue(relaunchedStore.learningItems.isEmpty)
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }

    @MainActor
    func testOptimisticEditRemovesLearningItemThatNoLongerMatchesSearch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "searched-card", expression: "古い")
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        try container.mainContext.save()
        let item = try XCTUnwrap(StudyCardCatalogRepository.standaloneLearningItems(from: [card], matching: "古い").first)
        let page = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [item], limit: 20, nextCursor: nil))
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, page
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.refreshLearningItems(search: "古い")

        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        XCTAssertTrue(store.learningItems.isEmpty)
    }
}

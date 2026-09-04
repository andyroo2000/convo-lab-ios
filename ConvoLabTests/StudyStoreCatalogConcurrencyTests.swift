import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testNewCardQueueLoadMoreCannotAppendAfterNewerRefreshReusesCursor() async throws {
        func item(id: String) -> StudyNewCardQueueItem {
            StudyNewCardQueueItem(
                id: id, noteId: id, cardType: "recognition", displayText: id, meaning: "meaning", queuePosition: 1,
                createdAt: .now, updatedAt: .now)
        }
        func page(item: StudyNewCardQueueItem, nextCursor: String?) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(items: [item], total: 2, limit: 100, nextCursor: nextCursor))
        }
        let initialItem = item(id: "initial")
        let refreshedItem = item(id: "refreshed")
        let staleNextPageItem = item(id: "stale-next-page")
        OverlappingCardListPageURLProtocol.configure(
            initialPage: try page(item: initialItem, nextCursor: "shared"),
            refreshedPage: try page(item: refreshedItem, nextCursor: "shared"),
            staleNextPage: try page(item: staleNextPageItem, nextCursor: nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingCardListPageURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshNewCardQueue()
        let staleLoadMore = Task { try await store.loadMoreNewCardQueue() }
        await waitUntil { OverlappingCardListPageURLProtocol.hasPendingNextPage }
        XCTAssertTrue(OverlappingCardListPageURLProtocol.hasPendingNextPage)

        try await store.refreshNewCardQueue()
        XCTAssertEqual(store.newCardQueue.map(\.id), [refreshedItem.id])
        OverlappingCardListPageURLProtocol.releasePendingNextPage()
        try await staleLoadMore.value

        XCTAssertEqual(store.newCardQueue.map(\.id), [refreshedItem.id])
        XCTAssertEqual(store.newCardQueueNextCursor, "shared")
    }

    @MainActor
    func testNewCardQueueReorderCannotOverwriteNewerRefresh() async throws {
        func item(id: String, position: Int) -> StudyNewCardQueueItem {
            StudyNewCardQueueItem(
                id: id, noteId: id, cardType: "recognition", displayText: id, meaning: "meaning",
                queuePosition: position, createdAt: .now, updatedAt: .now)
        }
        func page(items: [StudyNewCardQueueItem]) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(items: items, total: items.count, limit: 100, nextCursor: nil))
        }
        let first = item(id: "first", position: 1)
        let second = item(id: "second", position: 2)
        let refreshed = item(id: "refreshed", position: 1)
        let initialPage = try page(items: [first, second])
        let refreshedPage = try page(items: [refreshed])
        let reorderPage = try page(items: [second, first])

        for reorderStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(.init(
                initialPage: initialPage, refreshedPage: refreshedPage, reorderPage: reorderPage,
                reorderStatus: reorderStatus))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OverlappingQueueReorderURLProtocol.self]
            let client = APIClient(
                baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
            let container = try Persistence.makeContainer(inMemory: true)
            let store = StudyStore(
                initialUserID: 1, api: client, context: container.mainContext,
                mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

            try await store.refreshNewCardQueue()
            let staleReorder = Task { try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0) }
            await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingReorder }
            XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingReorder)

            try await store.refreshNewCardQueue()
            XCTAssertEqual(store.newCardQueue.map(\.id), [refreshed.id])
            OverlappingQueueReorderURLProtocol.releasePendingReorder()
            try await staleReorder.value

            XCTAssertEqual(store.newCardQueue.map(\.id), [refreshed.id])
        }
    }

    @MainActor
    func testNewCardQueueReorderDoesNotStartDuringRefresh() async throws {
        func item(id: String, position: Int) -> StudyNewCardQueueItem {
            StudyNewCardQueueItem(
                id: id, noteId: id, cardType: "recognition", displayText: id, meaning: "meaning",
                queuePosition: position, createdAt: .now, updatedAt: .now)
        }
        func page(items: [StudyNewCardQueueItem]) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(items: items, total: items.count, limit: 100, nextCursor: nil))
        }
        let first = item(id: "first", position: 1)
        let second = item(id: "second", position: 2)
        let refreshed = item(id: "refreshed", position: 1)
        OverlappingQueueReorderURLProtocol.configure(.init(
            initialPage: try page(items: [first, second]), refreshedPage: try page(items: [refreshed]),
            reorderPage: try page(items: [second, first]), reorderStatus: 200, holdSecondRefresh: true))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingQueueReorderURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        try await store.refreshNewCardQueue()

        let refresh = Task { try await store.refreshNewCardQueue() }
        await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingRefresh }
        XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingRefresh)
        let reorder = Task { try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        for _ in 0..<10 where !OverlappingQueueReorderURLProtocol.hasPendingReorder {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(OverlappingQueueReorderURLProtocol.hasPendingReorder)
        OverlappingQueueReorderURLProtocol.releasePendingRefresh()
        try await refresh.value
        OverlappingQueueReorderURLProtocol.releasePendingReorder()
        try await reorder.value
        XCTAssertEqual(store.newCardQueue.map(\.id), [refreshed.id])
    }

    @MainActor
    func testLatestAllCardsSearchWinsWhenAnOlderRefreshFinishesLast() async throws {
        let firstCard = makeCard(id: "01J00000000000000000000031", expression: "古い")
        let secondCard = makeCard(id: "01J00000000000000000000032", expression: "新しい")
        let firstPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard], limit: 50, nextCursor: "old-cursor"))
        let secondPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [secondCard], limit: 50, nextCursor: "new-cursor"))
        OutOfOrderCardListURLProtocol.configure(first: firstPage, second: secondPage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderCardListURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        let firstRefresh = Task { try await store.refreshAllCards(search: "first") }
        await waitUntil { OutOfOrderCardListURLProtocol.hasPendingFirstRequest }
        try await store.refreshAllCards(search: "second")
        try await firstRefresh.value

        XCTAssertEqual(store.allCards.map(\.id), [secondCard.id])
        XCTAssertEqual(store.allCardsQuery, "second")
        XCTAssertEqual(store.allCardsNextCursor, "new-cursor")
    }

    @MainActor
    func testLatestLearningItemSearchWinsWhenAnOlderRefreshFinishesLast() async throws {
        let firstCard = makeCard(id: "01J00000000000000000000033", expression: "古い")
        let secondCard = makeCard(id: "01J00000000000000000000034", expression: "新しい")
        let firstItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [firstCard], matching: "").first)
        let secondItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [secondCard], matching: "").first)
        let firstPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [firstItem], limit: 20, nextCursor: "old-cursor"))
        let secondPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [secondItem], limit: 20, nextCursor: "new-cursor"))
        OutOfOrderCardListURLProtocol.configure(first: firstPage, second: secondPage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderCardListURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        let firstRefresh = Task { try await store.refreshLearningItems(search: "first") }
        await waitUntil { OutOfOrderCardListURLProtocol.hasPendingFirstRequest }
        try await store.refreshLearningItems(search: "second")
        try await firstRefresh.value

        XCTAssertEqual(store.learningItems.map(\.id), [secondItem.id])
        XCTAssertEqual(store.learningItemsQuery, "second")
        XCTAssertEqual(store.learningItemsNextCursor, "new-cursor")
    }

    @MainActor
    func testAllCardsLoadMoreCannotAppendAfterNewerRefreshReusesCursor() async throws {
        let initialCard = makeCard(id: "initial", expression: "Initial")
        let refreshedCard = makeCard(id: "refreshed", expression: "Refreshed")
        let staleNextPageCard = makeCard(id: "stale-next-page", expression: "Stale")
        let initialPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [initialCard], limit: 50, nextCursor: "shared"))
        let refreshedPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [refreshedCard], limit: 50, nextCursor: "shared"))
        let staleNextPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [staleNextPageCard], limit: 50, nextCursor: nil))
        OverlappingCardListPageURLProtocol.configure(
            initialPage: initialPage, refreshedPage: refreshedPage, staleNextPage: staleNextPage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingCardListPageURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshAllCards(search: "same")
        let staleLoadMore = Task { try await store.loadMoreAllCards() }
        await waitUntil { OverlappingCardListPageURLProtocol.hasPendingNextPage }
        XCTAssertTrue(OverlappingCardListPageURLProtocol.hasPendingNextPage)

        try await store.refreshAllCards(search: "same")
        XCTAssertEqual(store.allCards.map(\.id), [refreshedCard.id])
        OverlappingCardListPageURLProtocol.releasePendingNextPage()
        try await staleLoadMore.value

        XCTAssertEqual(store.allCards.map(\.id), [refreshedCard.id])
        XCTAssertEqual(store.allCardsNextCursor, "shared")
    }
}

import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testNewCardQueueRefreshAndReorderUseCompatibilityAPI() async throws {
        let firstID = "01J00000000000000000000001"
        let secondID = "01J00000000000000000000002"
        let queueResponse: @Sendable (String, String) -> Data = { first, second in
            Data(
                """
                {
                  "items": [
                    {
                      "id": "\(first)",
                      "noteId": "\(first)",
                      "cardType": "recognition",
                      "displayText": "\(first == firstID ? "犬" : "猫")",
                      "meaning": "\(first == firstID ? "dog" : "cat")",
                      "queuePosition": 1,
                      "createdAt": "2026-07-25T12:00:00.000Z",
                      "updatedAt": "2026-07-25T12:00:00.000Z"
                    },
                    {
                      "id": "\(second)",
                      "noteId": "\(second)",
                      "cardType": "recognition",
                      "displayText": "\(second == secondID ? "猫" : "犬")",
                      "meaning": "\(second == secondID ? "cat" : "dog")",
                      "queuePosition": 2,
                      "createdAt": "2026-07-25T12:00:00.000Z",
                      "updatedAt": "2026-07-25T12:00:00.000Z"
                    }
                  ],
                  "total": 2,
                  "limit": 100,
                  "nextCursor": null
                }
                """.utf8)
        }
        let client = makeClient { request in
            let path = request.url?.path
            if path == "/api/study/new-queue" {
                XCTAssertEqual(request.url?.query, "limit=100")
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, queueResponse(firstID, secondID)
                )
            }

            XCTAssertEqual(path, "/api/study/new-queue/reorder")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            XCTAssertEqual(object["cardIds"] as? [String], [secondID, firstID])
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, queueResponse(secondID, firstID)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshNewCardQueue()

        XCTAssertEqual(store.newCardQueue.map(\.id), [firstID, secondID])
        XCTAssertEqual(store.newCardQueueTotal, 2)

        try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(store.newCardQueue.map(\.id), [secondID, firstID])
        XCTAssertEqual(store.newCardQueue.map(\.queuePosition), [1, 2])
    }

    @MainActor
    func testCardLibraryLoadsQueueAndAllCardsAcrossCursorPagesWithoutDuplicates() async throws {
        let firstCard = makeCard(id: "01J00000000000000000000011", expression: "犬")
        let secondCard = makeCard(id: "01J00000000000000000000012", expression: "猫")
        let firstQueueItem = StudyNewCardQueueItem(
            id: firstCard.id, noteId: firstCard.id, cardType: "recognition", displayText: "犬", meaning: "dog",
            queuePosition: 1, createdAt: .now, updatedAt: .now)
        let secondQueueItem = StudyNewCardQueueItem(
            id: secondCard.id, noteId: secondCard.id, cardType: "recognition", displayText: "猫", meaning: "cat",
            queuePosition: 2, createdAt: .now, updatedAt: .now)
        let firstQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(items: [firstQueueItem], total: 2, limit: 100, nextCursor: "1"))
        let secondQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(items: [firstQueueItem, secondQueueItem], total: 2, limit: 100, nextCursor: nil))
        let firstCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard], limit: 50, nextCursor: "cards-2"))
        let secondCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard, secondCard], limit: 50, nextCursor: nil))
        let client = makeClient { request in
            let query = request.url?.query ?? ""
            let data: Data
            switch (request.url?.path, query) {
            case ("/api/study/new-queue", "limit=100"): data = firstQueuePage
            case ("/api/study/new-queue", "cursor=1&limit=100"): data = secondQueuePage
            case ("/api/study/cards", "per_page=50&q=animal"): data = firstCardPage
            case ("/api/study/cards", "cursor=cards-2&per_page=50&q=animal"): data = secondCardPage
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, data
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshNewCardQueue()
        try await store.loadMoreNewCardQueue()
        try await store.refreshAllCards(search: "animal")
        try await store.loadMoreAllCards()

        XCTAssertEqual(store.newCardQueue.map(\.id), [firstCard.id, secondCard.id])
        XCTAssertNil(store.newCardQueueNextCursor)
        XCTAssertEqual(store.allCards.map(\.id), [firstCard.id, secondCard.id])
        XCTAssertNil(store.allCardsNextCursor)
    }

    @MainActor
    func testLearningItemLibraryLoadsWholeFamiliesAcrossCursorPagesWithoutDuplicates() async throws {
        let sentence = StudyLearningItemCard(
            id: "client-sentence", syncId: "server-sentence", noteId: nil, cardType: "recognition",
            displayText: "会社で働いています。", meaning: "I work at a company.", variantKind: "sentence_audio_recognition")
        let word = StudyLearningItemCard(
            id: "client-word", syncId: "server-word", noteId: nil, cardType: "recognition", displayText: "会社",
            meaning: "company", variantKind: "word_audio_recognition")
        let family = StudyLearningItem(
            id: "path:company", groupId: "company", representativeCard: sentence, currentStageNumber: 1, stageCount: 2,
            cardCount: 2, retiredStageCount: 0, transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1, status: .available, cardCount: 1, representativeCard: sentence, cards: [sentence]),
                StudyLearningItemStage(
                    number: 2, status: .locked, cardCount: 1, representativeCard: word, cards: [word]),
            ])
        let standalone = StudyLearningItem(
            id: "card:cat", groupId: nil,
            representativeCard: StudyLearningItemCard(
                id: "cat", syncId: "cat", noteId: nil, cardType: "recognition", displayText: "猫", meaning: "cat",
                variantKind: nil), currentStageNumber: nil, stageCount: 1, cardCount: 1, retiredStageCount: 0,
            transferDemonstrated: false, stages: [])
        let firstPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [family], limit: 20, nextCursor: "items-2"))
        let secondPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [family, standalone], limit: 20, nextCursor: nil))
        let client = makeClient { request in
            let data: Data
            switch request.url?.query {
            case "per_page=20&q=animal": data = firstPage
            case "cursor=items-2&per_page=20&q=animal": data = secondPage
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, data
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshLearningItems(search: "animal")
        try await store.loadMoreLearningItems()

        XCTAssertEqual(store.learningItems.map { $0.id }, [family.id, standalone.id])
        XCTAssertEqual(
            store.learningItems.first?.stages.map { $0.status }, [StudyLearningItemStageStatus.available, .locked])
        XCTAssertNil(store.learningItemsNextCursor)
    }

    @MainActor
    func testCancelledLearningItemRefreshPreservesExistingGroupedResults() async throws {
        let card = StudyLearningItemCard(
            id: "client-sentence", syncId: "server-sentence", noteId: nil, cardType: "recognition",
            displayText: "会社で働いています。", meaning: "I work at a company.", variantKind: "sentence_audio_recognition")
        let family = StudyLearningItem(
            id: "path:company", groupId: "company", representativeCard: card, currentStageNumber: 1, stageCount: 1,
            cardCount: 1, retiredStageCount: 0, transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1, status: .available, cardCount: 1, representativeCard: card, cards: [card])
            ])
        CancellableLearningItemURLProtocol.configure(
            response: try StorageCodec.encoder.encode(
                StudyLearningItemListResponse(items: [family], limit: 20, nextCursor: nil)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellableLearningItemURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        try await store.refreshLearningItems()
        let cancelledRefresh = Task { try await store.refreshLearningItems(search: "company") }
        await waitUntil { CancellableLearningItemURLProtocol.hasPendingRequest }
        XCTAssertTrue(CancellableLearningItemURLProtocol.hasPendingRequest)

        cancelledRefresh.cancel()
        try await cancelledRefresh.value

        XCTAssertEqual(store.learningItems, [family])
    }
}

final class CancellableLearningItemURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var pendingRequest: CancellableLearningItemURLProtocol?

    static var hasPendingRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequest != nil
    }

    static func configure(response: Data) {
        lock.lock()
        responseData = response
        requestCount = 0
        pendingRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let shouldRespond = Self.requestCount == 1
        let data = Self.responseData
        if !shouldRespond { Self.pendingRequest = self }
        Self.lock.unlock()

        guard shouldRespond else { return }
        respond(with: data)
    }

    override func stopLoading() {
        Self.lock.lock()
        let wasPending = Self.pendingRequest === self
        if wasPending { Self.pendingRequest = nil }
        Self.lock.unlock()
        guard wasPending else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

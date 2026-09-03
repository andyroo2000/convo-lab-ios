import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testResolveLearningItemCardFetchesMissingServerCardForEditing() async throws {
        let serverCard = makeCard(id: "server-card", expression: "猫")
        let serverCardID = serverCard.id
        let compactCard = StudyLearningItemCard(
            id: "client-card", syncId: serverCardID, noteId: serverCard.noteId, cardType: serverCard.cardType,
            displayText: "猫", meaning: "cat", variantKind: nil)
        let response = try StorageCodec.encoder.encode(["cards": [serverCard]])
        let client = makeClient { request in
            guard request.url?.path == "/api/study/cards/batch" else { throw URLError(.notConnectedToInternet) }
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            XCTAssertEqual(body["ids"] as? [String], [serverCardID])
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, response
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        let resolved = try await store.resolveCard(for: compactCard)

        XCTAssertEqual(resolved?.id, serverCardID)
        XCTAssertEqual(resolved?.promptText, serverCard.promptText)
        XCTAssertEqual(store.card(for: compactCard)?.id, serverCardID)

        let editableCard = try XCTUnwrap(resolved)
        try await store.updateCard(editableCard, prompt: "子猫", reading: "こねこ", answer: "kitten")
        let updatedCard = try XCTUnwrap(store.card(for: compactCard))
        XCTAssertEqual(updatedCard.promptText, "子猫")

        try await store.deleteCard(updatedCard)
        XCTAssertNil(store.card(for: compactCard))
    }

    @MainActor
    func testResolveNewQueueItemFetchesMissingServerCardForEditing() async throws {
        let serverCard = makeCard(id: "queued-server-card", expression: "犬")
        let serverCardID = serverCard.id
        let queueItem = StudyNewCardQueueItem(
            id: serverCardID, noteId: serverCard.noteId ?? serverCardID, cardType: serverCard.cardType,
            displayText: "犬", meaning: "dog", queuePosition: 1, createdAt: serverCard.createdAt,
            updatedAt: serverCard.updatedAt)
        let response = try StorageCodec.encoder.encode(["cards": [serverCard]])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            XCTAssertEqual(body["ids"] as? [String], [serverCardID])
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, response
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        let resolved = try await store.resolveCard(for: queueItem)

        XCTAssertEqual(resolved?.id, serverCardID)
        XCTAssertEqual(resolved?.promptText, serverCard.promptText)
    }

    @MainActor
    func testOptimisticCardEditsAndDeletesReconcileGroupedLearningItems() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "optimistic-card", expression: "古い")
        let laterCard = makeCard(id: "optimistic-card-2", expression: "次")
        let standaloneCard = makeCard(id: "standalone-survivor", expression: "別")
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        container.mainContext.insert(
            LocalCardRecord(
                card: laterCard, userID: 1, queueIndex: 1, payload: try StorageCodec.encoder.encode(laterCard)))
        container.mainContext.insert(
            LocalCardRecord(
                card: standaloneCard, userID: 1, queueIndex: 2, payload: try StorageCodec.encoder.encode(standaloneCard)
            ))
        try container.mainContext.save()
        let compactCard = StudyLearningItemCard(
            id: card.id, syncId: card.reviewCardID, noteId: card.noteId, cardType: card.cardType,
            displayText: card.promptText, meaning: card.answerText, variantKind: "sentence_text_recognition")
        let laterCompactCard = StudyLearningItemCard(
            id: laterCard.id, syncId: laterCard.reviewCardID, noteId: laterCard.noteId, cardType: laterCard.cardType,
            displayText: laterCard.promptText, meaning: laterCard.answerText, variantKind: "word_recognition")
        let family = StudyLearningItem(
            id: "path:optimistic", groupId: "optimistic", representativeCard: compactCard, currentStageNumber: 1,
            stageCount: 2, cardCount: 2, retiredStageCount: 0, transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1, status: .available, cardCount: 1, representativeCard: compactCard, cards: [compactCard]),
                StudyLearningItemStage(
                    number: 2, status: .locked, cardCount: 1, representativeCard: laterCompactCard,
                    cards: [laterCompactCard]),
            ])
        let standaloneItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [standaloneCard], matching: "").first)
        let page = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [family, standaloneItem], limit: 20, nextCursor: nil))
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
        try await store.refreshLearningItems()

        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        XCTAssertEqual(store.learningItems.first?.representativeCard.displayText, "新しい")
        XCTAssertEqual(store.learningItems.first?.representativeCard.meaning, "new")
        XCTAssertEqual(store.learningItems.first?.stages.first?.cards.first?.displayText, "新しい")
        let updatedCard = try XCTUnwrap(store.card(for: compactCard))

        try await store.deleteCard(updatedCard)

        XCTAssertEqual(store.learningItems.count, 2)
        XCTAssertNil(store.learningItems.first?.currentStageNumber)
        XCTAssertEqual(store.learningItems.first?.stageCount, 1)
        XCTAssertEqual(store.learningItems.first?.cardCount, 1)
        XCTAssertEqual(store.learningItems.first?.stages.map(\.number), [2])
        XCTAssertTrue(store.learningItems.contains { $0.id == standaloneItem.id })
    }
}

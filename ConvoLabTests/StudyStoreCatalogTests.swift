import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testInitialLocalLearningItemFallbackIsPaged() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<45 {
            let card = makeCard(
                id: "local-card-\(index)",
                expression: "Card \(index)"
            )
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: 1,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        XCTAssertEqual(store.learningItems.count, 20)
        XCTAssertNotNil(store.learningItemsNextCursor)
        let firstPageIDs = Set(store.learningItems.map(\.representativeCard.id))

        // Background sync can reorder the local library while the cached
        // fallback is being paged. The pager must continue from its stable
        // identity snapshot rather than a fresh offset into this array.
        store.libraryCards.reverse()

        try await store.loadMoreLearningItems()
        XCTAssertEqual(store.learningItems.count, 40)
        XCTAssertEqual(Set(store.learningItems.map(\.representativeCard.id)).count, 40)
        XCTAssertTrue(firstPageIDs.isSubset(of: Set(
            store.learningItems.map(\.representativeCard.id)
        )))
        XCTAssertNotNil(store.learningItemsNextCursor)

        try await store.loadMoreLearningItems()
        XCTAssertEqual(store.learningItems.count, 45)
        XCTAssertEqual(Set(store.learningItems.map(\.representativeCard.id)).count, 45)
        XCTAssertNil(store.learningItemsNextCursor)
        Self.retainedObservableStores.append(store)
    }

    @MainActor
    func testCardLookupUsesAliasesAndPrefersServerPresentation() {
        let fallback = makeCard(
            id: "local-card",
            syncId: "server-card",
            expression: "Cached"
        )
        let preferred = makeCard(
            id: "server-card",
            expression: "Server"
        )
        let lookup = StudyCardLookup(preferred: [preferred], fallback: [fallback])

        XCTAssertEqual(lookup.card(matching: ["local-card"])?.promptText, "Cached")
        XCTAssertEqual(lookup.card(matching: ["server-card"])?.promptText, "Server")
        XCTAssertEqual(lookup.card(matching: ["SERVER-CARD"])?.promptText, "Server")
    }

    @MainActor
    func testCardCatalogSnapshotIsVisibleOnRelaunchWithoutRefetching() async throws {
        let suiteName = "StudyStoreCatalogTests.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queueItem = StudyNewCardQueueItem(
            id: "cached-queue-card",
            noteId: "cached-queue-note",
            cardType: "recognition",
            displayText: "犬",
            meaning: "dog",
            queuePosition: 1,
            createdAt: .now,
            updatedAt: .now
        )
        let card = makeCard(id: "cached-learning-card", expression: "猫")
        let learningItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [card],
                matching: ""
            ).first
        )
        let cachedDraft = StudyManualCardDraft(
            id: "cached-manual-draft",
            status: "ready",
            committedCardId: nil,
            creationKind: .textRecognition,
            cardType: "recognition",
            prompt: .object(["cueText": .string("忘れない")]),
            answer: .object(["meaning": .string("not to forget")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let refreshedAt = Date.now
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(
            StudyCardCatalogSnapshot(
                savedAt: refreshedAt,
                newCardQueue: [queueItem],
                newCardQueueTotal: 1,
                newCardQueueNextCursor: nil,
                newCardQueueRefreshedAt: refreshedAt,
                learningItems: [learningItem],
                learningItemsNextCursor: nil,
                learningItemsRefreshedAt: refreshedAt
            ),
            userID: 1
        )
        cache.saveManualDrafts(
            StudyManualDraftSnapshot(
                savedAt: refreshedAt,
                drafts: [cachedDraft],
                refreshedAt: refreshedAt
            ),
            userID: 1
        )
        let requestPaths = LockedRequestPaths()
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")
            throw URLError(.notConnectedToInternet)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            cardCatalogSnapshotCache: cache
        )

        XCTAssertEqual(store.newCardQueue.map(\.id), [queueItem.id])
        XCTAssertEqual(store.newCardQueue.map(\.displayText), [queueItem.displayText])
        XCTAssertEqual(store.learningItems.map(\.id), [learningItem.id])
        XCTAssertEqual(store.manualDrafts.map(\.id), [cachedDraft.id])
        XCTAssertFalse(store.isRefreshingNewCardQueue)
        XCTAssertFalse(store.isRefreshingLearningItems)

        try await store.refreshManualDraftsIfNeeded()
        try await store.refreshNewCardQueueIfNeeded()
        try await store.refreshLearningItemsIfNeeded()

        XCTAssertTrue(requestPaths.values.isEmpty)
        let updatedDraft = StudyManualCardDraft(
            id: cachedDraft.id,
            status: cachedDraft.status,
            committedCardId: cachedDraft.committedCardId,
            creationKind: cachedDraft.creationKind,
            cardType: cachedDraft.cardType,
            prompt: cachedDraft.prompt,
            answer: .object(["meaning": .string("always remember")]),
            imagePlacement: cachedDraft.imagePlacement,
            imagePrompt: cachedDraft.imagePrompt,
            previewAudio: cachedDraft.previewAudio,
            previewAudioRole: cachedDraft.previewAudioRole,
            previewImage: cachedDraft.previewImage,
            errorMessage: cachedDraft.errorMessage,
            createdAt: cachedDraft.createdAt,
            updatedAt: .now
        )
        store.replaceManualDraft(updatedDraft)

        let relaunchedContainer = try Persistence.makeContainer(inMemory: true)
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: client,
            context: relaunchedContainer.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: relaunchedContainer.mainContext
            ),
            cardCatalogSnapshotCache: cache
        )
        XCTAssertEqual(relaunchedStore.manualDrafts.first?.answer, updatedDraft.answer)

        try relaunchedStore.deleteLocalData(userID: 1)
        XCTAssertNil(cache.load(userID: 1))
        XCTAssertNil(cache.loadManualDrafts(userID: 1))
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }

    @MainActor
    func testPendingDeleteCannotReappearFromCachedNewCardQueueAfterRelaunch() async throws {
        let suiteName = "StudyStoreCatalogTests.queue-delete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let card = makeCard(
            id: "cached-new-card-delete",
            expression: "消す",
            queueState: "new"
        )
        let queueItem = StudyNewCardQueueItem(
            id: card.id,
            noteId: card.noteId ?? card.id,
            cardType: card.cardType,
            displayText: card.promptText,
            meaning: card.answerText,
            queuePosition: 1,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt
        )
        let refreshedAt = Date.now
        let staleSnapshot = StudyCardCatalogSnapshot(
            savedAt: refreshedAt,
            newCardQueue: [queueItem],
            newCardQueueTotal: 1,
            newCardQueueNextCursor: nil,
            newCardQueueRefreshedAt: refreshedAt,
            learningItems: [],
            learningItemsNextCursor: nil,
            learningItemsRefreshedAt: refreshedAt
        )
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(staleSnapshot, userID: 1)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            cardCatalogSnapshotCache: cache
        )
        XCTAssertEqual(store.newCardQueue.map(\.id), [card.id])

        try await store.updateCard(card, prompt: "更新", reading: "", answer: "updated")
        XCTAssertEqual(store.newCardQueue.first?.displayText, "更新")
        XCTAssertEqual(store.newCardQueue.first?.meaning, "updated")

        try await store.deleteCard(card)

        XCTAssertTrue(store.newCardQueue.isEmpty)
        XCTAssertEqual(store.newCardQueueTotal, 0)
        store.deactivate()

        // Model an older cached payload surviving a termination between the
        // durable outbox write and a presentation-snapshot rewrite.
        cache.save(staleSnapshot, userID: 1)
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            cardCatalogSnapshotCache: cache
        )

        XCTAssertTrue(relaunchedStore.newCardQueue.isEmpty)
        XCTAssertEqual(relaunchedStore.newCardQueueTotal, 0)
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }

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
                """.utf8
            )
        }
        let client = makeClient { request in
            let path = request.url?.path
            if path == "/api/study/new-queue" {
                XCTAssertEqual(request.url?.query, "limit=100")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    queueResponse(firstID, secondID)
                )
            }

            XCTAssertEqual(path, "/api/study/new-queue/reorder")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(object["cardIds"] as? [String], [secondID, firstID])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                queueResponse(secondID, firstID)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

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
            id: firstCard.id,
            noteId: firstCard.id,
            cardType: "recognition",
            displayText: "犬",
            meaning: "dog",
            queuePosition: 1,
            createdAt: .now,
            updatedAt: .now
        )
        let secondQueueItem = StudyNewCardQueueItem(
            id: secondCard.id,
            noteId: secondCard.id,
            cardType: "recognition",
            displayText: "猫",
            meaning: "cat",
            queuePosition: 2,
            createdAt: .now,
            updatedAt: .now
        )
        let firstQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: [firstQueueItem],
                total: 2,
                limit: 100,
                nextCursor: "1"
            )
        )
        let secondQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: [firstQueueItem, secondQueueItem],
                total: 2,
                limit: 100,
                nextCursor: nil
            )
        )
        let firstCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard], limit: 50, nextCursor: "cards-2")
        )
        let secondCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard, secondCard], limit: 50, nextCursor: nil)
        )
        let client = makeClient { request in
            let query = request.url?.query ?? ""
            let data: Data
            switch (request.url?.path, query) {
            case ("/api/study/new-queue", "limit=100"):
                data = firstQueuePage
            case ("/api/study/new-queue", "cursor=1&limit=100"):
                data = secondQueuePage
            case ("/api/study/cards", "per_page=50&q=animal"):
                data = firstCardPage
            case ("/api/study/cards", "cursor=cards-2&per_page=50&q=animal"):
                data = secondCardPage
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
            id: "client-sentence",
            syncId: "server-sentence",
            noteId: nil,
            cardType: "recognition",
            displayText: "会社で働いています。",
            meaning: "I work at a company.",
            variantKind: "sentence_audio_recognition"
        )
        let word = StudyLearningItemCard(
            id: "client-word",
            syncId: "server-word",
            noteId: nil,
            cardType: "recognition",
            displayText: "会社",
            meaning: "company",
            variantKind: "word_audio_recognition"
        )
        let family = StudyLearningItem(
            id: "path:company",
            groupId: "company",
            representativeCard: sentence,
            currentStageNumber: 1,
            stageCount: 2,
            cardCount: 2,
            retiredStageCount: 0,
            transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1,
                    status: .available,
                    cardCount: 1,
                    representativeCard: sentence,
                    cards: [sentence]
                ),
                StudyLearningItemStage(
                    number: 2,
                    status: .locked,
                    cardCount: 1,
                    representativeCard: word,
                    cards: [word]
                ),
            ]
        )
        let standalone = StudyLearningItem(
            id: "card:cat",
            groupId: nil,
            representativeCard: StudyLearningItemCard(
                id: "cat",
                syncId: "cat",
                noteId: nil,
                cardType: "recognition",
                displayText: "猫",
                meaning: "cat",
                variantKind: nil
            ),
            currentStageNumber: nil,
            stageCount: 1,
            cardCount: 1,
            retiredStageCount: 0,
            transferDemonstrated: false,
            stages: []
        )
        let firstPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [family],
                limit: 20,
                nextCursor: "items-2"
            )
        )
        let secondPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [family, standalone],
                limit: 20,
                nextCursor: nil
            )
        )
        let client = makeClient { request in
            let data: Data
            switch request.url?.query {
            case "per_page=20&q=animal":
                data = firstPage
            case "cursor=items-2&per_page=20&q=animal":
                data = secondPage
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshLearningItems(search: "animal")
        try await store.loadMoreLearningItems()

        XCTAssertEqual(store.learningItems.map { $0.id }, [family.id, standalone.id])
        XCTAssertEqual(
            store.learningItems.first?.stages.map { $0.status },
            [StudyLearningItemStageStatus.available, .locked]
        )
        XCTAssertNil(store.learningItemsNextCursor)
    }

    @MainActor
    func testCancelledLearningItemRefreshPreservesExistingGroupedResults() async throws {
        let card = StudyLearningItemCard(
            id: "client-sentence",
            syncId: "server-sentence",
            noteId: nil,
            cardType: "recognition",
            displayText: "会社で働いています。",
            meaning: "I work at a company.",
            variantKind: "sentence_audio_recognition"
        )
        let family = StudyLearningItem(
            id: "path:company",
            groupId: "company",
            representativeCard: card,
            currentStageNumber: 1,
            stageCount: 1,
            cardCount: 1,
            retiredStageCount: 0,
            transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1,
                    status: .available,
                    cardCount: 1,
                    representativeCard: card,
                    cards: [card]
                )
            ]
        )
        CancellableLearningItemURLProtocol.configure(
            response: try StorageCodec.encoder.encode(
                StudyLearningItemListResponse(items: [family], limit: 20, nextCursor: nil)
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellableLearningItemURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshLearningItems()
        let cancelledRefresh = Task { try await store.refreshLearningItems(search: "company") }
        await waitUntil { CancellableLearningItemURLProtocol.hasPendingRequest }
        XCTAssertTrue(CancellableLearningItemURLProtocol.hasPendingRequest)

        cancelledRefresh.cancel()
        try await cancelledRefresh.value

        XCTAssertEqual(store.learningItems, [family])
    }

    @MainActor
    func testResolveLearningItemCardFetchesMissingServerCardForEditing() async throws {
        let serverCard = makeCard(id: "server-card", expression: "猫")
        let serverCardID = serverCard.id
        let compactCard = StudyLearningItemCard(
            id: "client-card",
            syncId: serverCardID,
            noteId: serverCard.noteId,
            cardType: serverCard.cardType,
            displayText: "猫",
            meaning: "cat",
            variantKind: nil
        )
        let response = try StorageCodec.encoder.encode(["cards": [serverCard]])
        let client = makeClient { request in
            guard request.url?.path == "/api/study/cards/batch" else {
                throw URLError(.notConnectedToInternet)
            }
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(body["ids"] as? [String], [serverCardID])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                response
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let resolved = try await store.resolveCard(for: compactCard)

        XCTAssertEqual(resolved?.id, serverCardID)
        XCTAssertEqual(resolved?.promptText, serverCard.promptText)
        XCTAssertEqual(store.card(for: compactCard)?.id, serverCardID)

        let editableCard = try XCTUnwrap(resolved)
        try await store.updateCard(
            editableCard,
            prompt: "子猫",
            reading: "こねこ",
            answer: "kitten"
        )
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
            id: serverCardID,
            noteId: serverCard.noteId ?? serverCardID,
            cardType: serverCard.cardType,
            displayText: "犬",
            meaning: "dog",
            queuePosition: 1,
            createdAt: serverCard.createdAt,
            updatedAt: serverCard.updatedAt
        )
        let response = try StorageCodec.encoder.encode(["cards": [serverCard]])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(body["ids"] as? [String], [serverCardID])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                response
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: laterCard,
                userID: 1,
                queueIndex: 1,
                payload: try StorageCodec.encoder.encode(laterCard)
            )
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: standaloneCard,
                userID: 1,
                queueIndex: 2,
                payload: try StorageCodec.encoder.encode(standaloneCard)
            )
        )
        try container.mainContext.save()
        let compactCard = StudyLearningItemCard(
            id: card.id,
            syncId: card.reviewCardID,
            noteId: card.noteId,
            cardType: card.cardType,
            displayText: card.promptText,
            meaning: card.answerText,
            variantKind: "sentence_text_recognition"
        )
        let laterCompactCard = StudyLearningItemCard(
            id: laterCard.id,
            syncId: laterCard.reviewCardID,
            noteId: laterCard.noteId,
            cardType: laterCard.cardType,
            displayText: laterCard.promptText,
            meaning: laterCard.answerText,
            variantKind: "word_recognition"
        )
        let family = StudyLearningItem(
            id: "path:optimistic",
            groupId: "optimistic",
            representativeCard: compactCard,
            currentStageNumber: 1,
            stageCount: 2,
            cardCount: 2,
            retiredStageCount: 0,
            transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1,
                    status: .available,
                    cardCount: 1,
                    representativeCard: compactCard,
                    cards: [compactCard]
                ),
                StudyLearningItemStage(
                    number: 2,
                    status: .locked,
                    cardCount: 1,
                    representativeCard: laterCompactCard,
                    cards: [laterCompactCard]
                )
            ]
        )
        let standaloneItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [standaloneCard],
                matching: ""
            ).first
        )
        let page = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [family, standaloneItem],
                limit: 20,
                nextCursor: nil
            )
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    page
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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

    @MainActor
    func testRefreshPreservesPendingLocalCardCreation() async throws {
        let emptyPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [], limit: 20, nextCursor: nil)
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    emptyPage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [card],
                matching: ""
            ).first
        )
        let stalePage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil)
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    stalePage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [card],
                matching: ""
            ).first
        )
        let stalePage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil)
        )
        let learningItemRequests = LockedRequestPaths()
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                learningItemRequests.append(request.url?.absoluteString ?? "")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    stalePage
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
                    card: card,
                    userID: 1,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        try container.mainContext.save()
        let dogItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [dog],
                matching: ""
            ).first
        )
        let dogPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [dogItem], limit: 20, nextCursor: nil)
        )
        let client = makeClient { request in
            guard request.url?.query?.contains("q=Dog") == true else {
                throw URLError(.notConnectedToInternet)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                dogPage
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.refreshLearningItems(search: "Dog")

        do {
            try await store.refreshLearningItems(search: "")
            XCTFail("Expected the offline refresh to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.learningItemsQuery, "")
        XCTAssertEqual(
            Set(store.learningItems.map(\.representativeCard.id)),
            Set([dog.id, cat.id])
        )
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
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let staleItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [card],
                matching: ""
            ).first
        )
        let refreshedAt = Date.now
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(
            StudyCardCatalogSnapshot(
                savedAt: refreshedAt,
                newCardQueue: [],
                newCardQueueTotal: 0,
                newCardQueueNextCursor: nil,
                newCardQueueRefreshedAt: refreshedAt,
                learningItems: [staleItem],
                learningItemsNextCursor: nil,
                learningItemsRefreshedAt: refreshedAt
            ),
            userID: 1
        )
        let searchPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [staleItem], limit: 20, nextCursor: nil)
        )
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
                XCTFail(
                    "Unexpected request: "
                        + "\(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")"
                )
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: data.isEmpty ? nil : ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache
        )
        try await store.refreshLearningItems(search: "古い")

        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertEqual(
            cache.load(userID: 1)?.learningItems.first?.representativeCard.displayText,
            "新しい"
        )

        try await store.deleteCard(card)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(cache.load(userID: 1)?.learningItems.isEmpty == true)
        store.deactivate()

        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: offlineClient,
                context: container.mainContext
            ),
            cardCatalogSnapshotCache: cache
        )

        XCTAssertTrue(relaunchedStore.learningItems.isEmpty)
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }

    @MainActor
    func testOptimisticEditRemovesLearningItemThatNoLongerMatchesSearch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "searched-card", expression: "古い")
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let item = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [card],
                matching: "古い"
            ).first
        )
        let page = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(items: [item], limit: 20, nextCursor: nil)
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/learning-items" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    page
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshLearningItems(search: "古い")

        try await store.updateCard(card, prompt: "新しい", reading: "", answer: "new")

        XCTAssertTrue(store.learningItems.isEmpty)
    }

    @MainActor
    func testNewCardQueueLoadMoreCannotAppendAfterNewerRefreshReusesCursor() async throws {
        func item(id: String) -> StudyNewCardQueueItem {
            StudyNewCardQueueItem(
                id: id,
                noteId: id,
                cardType: "recognition",
                displayText: id,
                meaning: "meaning",
                queuePosition: 1,
                createdAt: .now,
                updatedAt: .now
            )
        }
        func page(item: StudyNewCardQueueItem, nextCursor: String?) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(
                    items: [item],
                    total: 2,
                    limit: 100,
                    nextCursor: nextCursor
                )
            )
        }
        let initialItem = item(id: "initial")
        let refreshedItem = item(id: "refreshed")
        let staleNextPageItem = item(id: "stale-next-page")
        OverlappingCardListPageURLProtocol.configure(
            initialPage: try page(item: initialItem, nextCursor: "shared"),
            refreshedPage: try page(item: refreshedItem, nextCursor: "shared"),
            staleNextPage: try page(item: staleNextPageItem, nextCursor: nil)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingCardListPageURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
                id: id,
                noteId: id,
                cardType: "recognition",
                displayText: id,
                meaning: "meaning",
                queuePosition: position,
                createdAt: .now,
                updatedAt: .now
            )
        }
        func page(items: [StudyNewCardQueueItem]) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(
                    items: items,
                    total: items.count,
                    limit: 100,
                    nextCursor: nil
                )
            )
        }
        let first = item(id: "first", position: 1)
        let second = item(id: "second", position: 2)
        let refreshed = item(id: "refreshed", position: 1)
        let initialPage = try page(items: [first, second])
        let refreshedPage = try page(items: [refreshed])
        let reorderPage = try page(items: [second, first])

        for reorderStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(
                initialPage: initialPage,
                refreshedPage: refreshedPage,
                reorderPage: reorderPage,
                reorderStatus: reorderStatus
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OverlappingQueueReorderURLProtocol.self]
            let client = APIClient(
                baseURL: URL(string: "https://learning-os.example")!,
                session: URLSession(configuration: configuration)
            )
            let container = try Persistence.makeContainer(inMemory: true)
            let store = StudyStore(
                initialUserID: 1,
                api: client,
                context: container.mainContext,
                mediaCache: MediaCache(
                    initialUserID: 1,
                    api: client,
                    context: container.mainContext
                )
            )

            try await store.refreshNewCardQueue()
            let staleReorder = Task {
                try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            }
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
                id: id,
                noteId: id,
                cardType: "recognition",
                displayText: id,
                meaning: "meaning",
                queuePosition: position,
                createdAt: .now,
                updatedAt: .now
            )
        }
        func page(items: [StudyNewCardQueueItem]) throws -> Data {
            try StorageCodec.encoder.encode(
                StudyNewCardQueueResponse(
                    items: items,
                    total: items.count,
                    limit: 100,
                    nextCursor: nil
                )
            )
        }
        let first = item(id: "first", position: 1)
        let second = item(id: "second", position: 2)
        let refreshed = item(id: "refreshed", position: 1)
        OverlappingQueueReorderURLProtocol.configure(
            initialPage: try page(items: [first, second]),
            refreshedPage: try page(items: [refreshed]),
            reorderPage: try page(items: [second, first]),
            reorderStatus: 200,
            holdSecondRefresh: true
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingQueueReorderURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshNewCardQueue()

        let refresh = Task { try await store.refreshNewCardQueue() }
        await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingRefresh }
        XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingRefresh)
        let reorder = Task {
            try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        }
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
    func testNewCardQueueLoadMoreDoesNotStartDuringReorder() async throws {
        let first = makeQueueItem(id: "first", position: 1)
        let second = makeQueueItem(id: "second", position: 2)
        let third = makeQueueItem(id: "third", position: 3)

        for reorderStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(
                initialPage: try queuePage(items: [first, second], total: 3, nextCursor: "next"),
                refreshedPage: Data(),
                reorderPage: try queuePage(
                    items: [second, first],
                    total: 3,
                    nextCursor: "next"
                ),
                reorderStatus: reorderStatus,
                nextPage: try queuePage(items: [third], total: 3, nextCursor: nil)
            )
            let store = try makeStore(protocolClass: OverlappingQueueReorderURLProtocol.self)
            try await store.refreshNewCardQueue()

            let reorder = Task { () -> Error? in
                do {
                    try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
                    return nil
                } catch {
                    return error
                }
            }
            await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingReorder }
            XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingReorder)
            let loadMore = Task { () -> Error? in
                do {
                    try await store.loadMoreNewCardQueue()
                    return nil
                } catch {
                    return error
                }
            }
            for _ in 0..<10 where !OverlappingQueueReorderURLProtocol.hasPendingLoadMore {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertFalse(OverlappingQueueReorderURLProtocol.hasPendingLoadMore)
            OverlappingQueueReorderURLProtocol.releasePendingLoadMore()
            let loadMoreError = await loadMore.value
            XCTAssertNil(loadMoreError)
            OverlappingQueueReorderURLProtocol.releasePendingReorder()
            let reorderError = await reorder.value

            if reorderStatus == 200 {
                XCTAssertNil(reorderError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [second.id, first.id])
            } else {
                XCTAssertNotNil(reorderError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id])
            }
            XCTAssertEqual(store.newCardQueueNextCursor, "next")
        }
    }

    @MainActor
    func testNewCardQueueReorderDoesNotStartDuringLoadMore() async throws {
        let first = makeQueueItem(id: "first", position: 1)
        let second = makeQueueItem(id: "second", position: 2)
        let third = makeQueueItem(id: "third", position: 3)

        for loadMoreStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(
                initialPage: try queuePage(items: [first, second], total: 3, nextCursor: "next"),
                refreshedPage: Data(),
                reorderPage: try queuePage(
                    items: [second, first],
                    total: 3,
                    nextCursor: "next"
                ),
                reorderStatus: 200,
                nextPage: try queuePage(items: [third], total: 3, nextCursor: nil),
                nextPageStatus: loadMoreStatus
            )
            let store = try makeStore(protocolClass: OverlappingQueueReorderURLProtocol.self)
            try await store.refreshNewCardQueue()

            let loadMore = Task { () -> Error? in
                do {
                    try await store.loadMoreNewCardQueue()
                    return nil
                } catch {
                    return error
                }
            }
            await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingLoadMore }
            XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingLoadMore)
            let reorder = Task { () -> Error? in
                do {
                    try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
                    return nil
                } catch {
                    return error
                }
            }
            for _ in 0..<10 where !OverlappingQueueReorderURLProtocol.hasPendingReorder {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertFalse(OverlappingQueueReorderURLProtocol.hasPendingReorder)
            OverlappingQueueReorderURLProtocol.releasePendingReorder()
            let reorderError = await reorder.value
            XCTAssertNil(reorderError)
            OverlappingQueueReorderURLProtocol.releasePendingLoadMore()
            let loadMoreError = await loadMore.value

            if loadMoreStatus == 200 {
                XCTAssertNil(loadMoreError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id, third.id])
                XCTAssertNil(store.newCardQueueNextCursor)
            } else {
                XCTAssertNotNil(loadMoreError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id])
                XCTAssertEqual(store.newCardQueueNextCursor, "next")
            }
        }
    }

    @MainActor
    func testAllCardsFallsBackToTheLocalReplicaWhenOffline() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dog = makeCard(id: "01J00000000000000000000021", expression: "犬")
        let cat = makeCard(id: "01J00000000000000000000022", expression: "猫")
        for (index, card) in [dog, cat].enumerated() {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: 1,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            try await store.refreshAllCards(search: "犬")
            XCTFail("Expected the remote card page to fail while offline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.allCards.map(\.id), [dog.id])
        XCTAssertEqual(store.allCardsQuery, "犬")
        XCTAssertNil(store.allCardsNextCursor)
    }

    @MainActor
    func testLearningItemsFallBackToTheLocalReplicaWhenOffline() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dog = makeCard(id: "01J00000000000000000000023", expression: "犬")
        let cat = makeCard(id: "01J00000000000000000000024", expression: "猫")
        for (index, card) in [dog, cat].enumerated() {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: 1,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            try await store.refreshLearningItems(search: "犬")
            XCTFail("Expected the remote learning-item page to fail while offline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.learningItems.map(\.representativeCard.id), [dog.id])
        XCTAssertEqual(store.learningItemsQuery, "犬")
        XCTAssertNil(store.learningItemsNextCursor)
    }

    @MainActor
    func testLatestAllCardsSearchWinsWhenAnOlderRefreshFinishesLast() async throws {
        let firstCard = makeCard(id: "01J00000000000000000000031", expression: "古い")
        let secondCard = makeCard(id: "01J00000000000000000000032", expression: "新しい")
        let firstPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard], limit: 50, nextCursor: "old-cursor")
        )
        let secondPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [secondCard], limit: 50, nextCursor: "new-cursor")
        )
        OutOfOrderCardListURLProtocol.configure(first: firstPage, second: secondPage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderCardListURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [firstCard],
                matching: ""
            ).first
        )
        let secondItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: [secondCard],
                matching: ""
            ).first
        )
        let firstPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [firstItem],
                limit: 20,
                nextCursor: "old-cursor"
            )
        )
        let secondPage = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [secondItem],
                limit: 20,
                nextCursor: "new-cursor"
            )
        )
        OutOfOrderCardListURLProtocol.configure(first: firstPage, second: secondPage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderCardListURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
            StudyCardListResponse(items: [initialCard], limit: 50, nextCursor: "shared")
        )
        let refreshedPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [refreshedCard], limit: 50, nextCursor: "shared")
        )
        let staleNextPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [staleNextPageCard], limit: 50, nextCursor: nil)
        )
        OverlappingCardListPageURLProtocol.configure(
            initialPage: initialPage,
            refreshedPage: refreshedPage,
            staleNextPage: staleNextPage
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverlappingCardListPageURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
        if !shouldRespond {
            Self.pendingRequest = self
        }
        Self.lock.unlock()

        guard shouldRespond else { return }
        respond(with: data)
    }

    override func stopLoading() {
        Self.lock.lock()
        let wasPending = Self.pendingRequest === self
        if wasPending {
            Self.pendingRequest = nil
        }
        Self.lock.unlock()
        guard wasPending else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

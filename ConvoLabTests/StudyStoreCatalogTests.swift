import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testInitialLocalLearningItemFallbackIsPaged() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<45 {
            let card = makeCard(id: "local-card-\(index)", expression: "Card \(index)")
            container.mainContext.insert(
                LocalCardRecord(
                    card: card, userID: 1, queueIndex: index, payload: try StorageCodec.encoder.encode(card)))
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

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
        XCTAssertTrue(firstPageIDs.isSubset(of: Set(store.learningItems.map(\.representativeCard.id))))
        XCTAssertNotNil(store.learningItemsNextCursor)

        try await store.loadMoreLearningItems()
        XCTAssertEqual(store.learningItems.count, 45)
        XCTAssertEqual(Set(store.learningItems.map(\.representativeCard.id)).count, 45)
        XCTAssertNil(store.learningItemsNextCursor)
        Self.retainedObservableStores.append(store)
    }

    @MainActor
    func testLocalFallbackRestoreKeepsOptimisticCardAndLoadedPageVisible() async throws {
        let suiteName = "StudyStoreCatalogTests.local-paging-restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<25 {
            let card = makeCard(id: "persisted-local-card-\(index)", expression: "Card \(index)")
            container.mainContext.insert(
                LocalCardRecord(
                    card: card, userID: 1, queueIndex: index, payload: try StorageCodec.encoder.encode(card)))
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)
        let initiallyVisibleIDs = Set(store.learningItems.map(\.representativeCard.id))
        XCTAssertEqual(initiallyVisibleIDs.count, 20)

        var draft = StudyCardDraft()
        draft.cueText = "Offline creation"
        draft.answerExpression = "Offline creation"
        draft.answerMeaning = "created offline"
        let optimistic = try await store.createCard(draft)
        XCTAssertEqual(store.learningItems.count, 21)
        store.deactivate()

        let relaunchedStore = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)
        let restoredIDs = Set(relaunchedStore.learningItems.map(\.representativeCard.id))

        XCTAssertEqual(restoredIDs.count, 21)
        XCTAssertTrue(restoredIDs.contains(optimistic.id))
        XCTAssertTrue(initiallyVisibleIDs.isSubset(of: restoredIDs))

        try await relaunchedStore.loadMoreLearningItems()
        XCTAssertEqual(relaunchedStore.learningItems.count, 26)
        XCTAssertEqual(Set(relaunchedStore.learningItems.map(\.representativeCard.id)).count, 26)
        XCTAssertNil(relaunchedStore.learningItemsNextCursor)
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }

    @MainActor
    func testCardLookupUsesAliasesAndPrefersServerPresentation() {
        let fallback = makeCard(id: "local-card", syncId: "server-card", expression: "Cached")
        let preferred = makeCard(id: "server-card", expression: "Server")
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
            id: "cached-queue-card", noteId: "cached-queue-note", cardType: "recognition", displayText: "犬",
            meaning: "dog", queuePosition: 1, createdAt: .now, updatedAt: .now)
        let card = makeCard(id: "cached-learning-card", expression: "猫")
        let learningItem = try XCTUnwrap(
            StudyCardCatalogRepository.standaloneLearningItems(from: [card], matching: "").first)
        let cachedDraft = StudyManualCardDraft(
            id: "cached-manual-draft", status: "ready", committedCardId: nil, creationKind: .textRecognition,
            cardType: "recognition", prompt: .object(["cueText": .string("忘れない")]),
            answer: .object(["meaning": .string("not to forget")]), imagePlacement: .none, imagePrompt: nil,
            previewAudio: nil, previewAudioRole: nil, previewImage: nil, errorMessage: nil, createdAt: .now,
            updatedAt: .now)
        let refreshedAt = Date.now
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(
            StudyCardCatalogSnapshot(
                savedAt: refreshedAt, newCardQueue: [queueItem], newCardQueueTotal: 1, newCardQueueNextCursor: nil,
                newCardQueueRefreshedAt: refreshedAt, learningItems: [learningItem], learningItemsNextCursor: nil,
                learningItemsRefreshedAt: refreshedAt), userID: 1)
        cache.saveManualDrafts(
            StudyManualDraftSnapshot(savedAt: refreshedAt, drafts: [cachedDraft], refreshedAt: refreshedAt), userID: 1)
        let requestPaths = LockedRequestPaths()
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")
            throw URLError(.notConnectedToInternet)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)

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
            id: cachedDraft.id, status: cachedDraft.status, committedCardId: cachedDraft.committedCardId,
            creationKind: cachedDraft.creationKind, cardType: cachedDraft.cardType, prompt: cachedDraft.prompt,
            answer: .object(["meaning": .string("always remember")]), imagePlacement: cachedDraft.imagePlacement,
            imagePrompt: cachedDraft.imagePrompt, previewAudio: cachedDraft.previewAudio,
            previewAudioRole: cachedDraft.previewAudioRole, previewImage: cachedDraft.previewImage,
            errorMessage: cachedDraft.errorMessage, createdAt: cachedDraft.createdAt, updatedAt: .now)
        store.replaceManualDraft(updatedDraft)

        let relaunchedContainer = try Persistence.makeContainer(inMemory: true)
        let relaunchedStore = StudyStore(
            initialUserID: 1, api: client, context: relaunchedContainer.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: relaunchedContainer.mainContext),
            cardCatalogSnapshotCache: cache)
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
        let card = makeCard(id: "cached-new-card-delete", expression: "消す", queueState: "new")
        let queueItem = StudyNewCardQueueItem(
            id: card.id, noteId: card.noteId ?? card.id, cardType: card.cardType, displayText: card.promptText,
            meaning: card.answerText, queuePosition: 1, createdAt: card.createdAt, updatedAt: card.updatedAt)
        let refreshedAt = Date.now
        let staleSnapshot = StudyCardCatalogSnapshot(
            savedAt: refreshedAt, newCardQueue: [queueItem], newCardQueueTotal: 1, newCardQueueNextCursor: nil,
            newCardQueueRefreshedAt: refreshedAt, learningItems: [], learningItemsNextCursor: nil,
            learningItemsRefreshedAt: refreshedAt)
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        cache.save(staleSnapshot, userID: 1)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: try StorageCodec.encoder.encode(card)))
        try container.mainContext.save()
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)
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
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext),
            cardCatalogSnapshotCache: cache)

        XCTAssertTrue(relaunchedStore.newCardQueue.isEmpty)
        XCTAssertEqual(relaunchedStore.newCardQueueTotal, 0)
        Self.retainedObservableStores.append(contentsOf: [store, relaunchedStore])
    }
}

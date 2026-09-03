import Foundation
import SwiftData

extension StudyStore {
    private static let localLearningItemPageSize = 20
    private static let localLearningItemCursorPrefix = "local-cache:"

    func learningPath(for card: StudyCard) async throws -> StudyLearningPath {
        let currentCard = try prepareLearningPathAccess(for: card)
        return try await learningPathRepository.learningPath(for: currentCard.reviewCardID)
    }

    func searchLearningPathSuccessors(matching query: String) async throws -> [StudyCard] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        return try await cardCatalogRepository.cardPage(matching: trimmedQuery).items
    }

    func linkLearningPathSuccessor(
        _ successor: StudyCard,
        to predecessor: StudyCard,
        requirement: StudyLearningPathUnlockRequirement
    ) async throws -> StudyLearningPath {
        let currentPredecessor = try prepareLearningPathAccess(for: predecessor)
        let currentSuccessor = try currentLocalCardIfPresent(for: successor) ?? successor
        for identifier in Set([currentSuccessor.id, currentSuccessor.reviewCardID]) {
            guard try !cardOutbox.hasPendingCardWrite(for: identifier) else {
                throw PendingLearningPathChangesError()
            }
        }
        let path = try await learningPathRepository.linkSuccessor(
            currentSuccessor.reviewCardID,
            to: currentPredecessor.reviewCardID,
            requirement: requirement
        )
        try? await refreshLearningItems(search: learningItemsQuery)
        return path
    }

    func refreshLearningItems(search query: String = "") async throws {
        guard let userID = activeUserID else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousQuery = learningItemsQuery
        var restoredDefaultSnapshot = false
        if trimmedQuery.isEmpty,
           !learningItemsQuery.isEmpty,
           let cardCatalogSnapshot
        {
            learningItems = cardCatalogSnapshot.learningItems
            learningItemsNextCursor = cardCatalogSnapshot.learningItemsNextCursor
            restoreLocalLearningItemFallbackCursor(
                cardCatalogSnapshot.learningItemsNextCursor
            )
            restoredDefaultSnapshot = true
        }
        let previousItems = learningItems
        let previousNextCursor = learningItemsNextCursor
        let previousLocalFallbackOffset = learningItemsLocalFallbackOffset
        let previousLocalFallbackIdentifiers = learningItemsLocalFallbackIdentifiers
        let previousItemsMatchRequestedQuery = previousQuery == trimmedQuery
            || restoredDefaultSnapshot
        learningItemsRefreshRevision += 1
        let refreshRevision = learningItemsRefreshRevision
        learningItemsQuery = trimmedQuery
        learningItemsNextCursor = nil
        isRefreshingLearningItems = true
        defer {
            if activeUserID == userID, learningItemsRefreshRevision == refreshRevision {
                isRefreshingLearningItems = false
            }
        }

        do {
            let response = try await cardCatalogRepository.learningItemPage(
                matching: trimmedQuery
            )
            guard
                activeUserID == userID,
                learningItemsRefreshRevision == refreshRevision,
                learningItemsQuery == trimmedQuery
            else { return }
            learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
                response.items,
                to: []
            )
            learningItemsLocalFallbackOffset = nil
            learningItemsLocalFallbackIdentifiers = nil
            reconcilePendingCardMutationsIntoLearningItems()
            learningItemsNextCursor = response.nextCursor
            if trimmedQuery.isEmpty {
                learningItemsRefreshedAt = .now
                persistCardCatalogSnapshot()
            }
        } catch {
            guard
                activeUserID == userID,
                learningItemsRefreshRevision == refreshRevision,
                learningItemsQuery == trimmedQuery
            else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            if trimmedQuery.isEmpty,
               previousItemsMatchRequestedQuery,
               !previousItems.isEmpty
            {
                learningItems = previousItems
                learningItemsNextCursor = previousNextCursor
                learningItemsLocalFallbackOffset = previousLocalFallbackOffset
                learningItemsLocalFallbackIdentifiers = previousLocalFallbackIdentifiers
                reconcilePendingCardMutationsIntoLearningItems()
            } else {
                installLocalLearningItemFallback(matching: trimmedQuery)
            }
            throw error
        }
    }

    func refreshLearningItemsIfNeeded(
        search query: String = "",
        maxAge: TimeInterval = 60
    ) async throws {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty else {
            try await refreshLearningItems(search: trimmedQuery)
            return
        }
        if !learningItemsQuery.isEmpty, let cardCatalogSnapshot {
            learningItems = cardCatalogSnapshot.learningItems
            learningItemsNextCursor = cardCatalogSnapshot.learningItemsNextCursor
            learningItemsQuery = ""
            restoreLocalLearningItemFallbackCursor(
                cardCatalogSnapshot.learningItemsNextCursor
            )
            reconcilePendingCardMutationsIntoLearningItems()
        }
        guard !isFresh(learningItemsRefreshedAt, maxAge: maxAge) else { return }
        try await refreshLearningItems()
    }

    func loadMoreLearningItems() async throws {
        guard
            let userID = activeUserID,
            !isRefreshingLearningItems,
            !isLoadingMoreLearningItems
        else { return }
        if let offset = learningItemsLocalFallbackOffset {
            loadMoreLocalLearningItems(
                offset: offset,
                userID: userID,
                query: learningItemsQuery
            )
            return
        }
        guard let cursor = learningItemsNextCursor else { return }
        let refreshRevision = learningItemsRefreshRevision
        let query = learningItemsQuery
        isLoadingMoreLearningItems = true
        defer {
            if activeUserID == userID {
                isLoadingMoreLearningItems = false
            }
        }

        let response = try await cardCatalogRepository.learningItemPage(
            matching: query,
            after: cursor
        )
        guard
            activeUserID == userID,
            learningItemsRefreshRevision == refreshRevision,
            learningItemsNextCursor == cursor,
            learningItemsQuery == query
        else { return }
        learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
            response.items,
            to: learningItems
        )
        learningItemsLocalFallbackOffset = nil
        learningItemsLocalFallbackIdentifiers = nil
        reconcilePendingCardMutationsIntoLearningItems()
        learningItemsNextCursor = response.nextCursor
        if query.isEmpty {
            persistCardCatalogSnapshot()
        }
    }

    func installLocalLearningItemFallback(matching query: String) {
        let matchingCards = StudyCardCatalogRepository.cards(
            libraryCards,
            matching: query
        )
        learningItemsLocalFallbackIdentifiers = matchingCards.map {
            Array(StudyCardIdentity.identifiers(for: $0)).sorted()
        }
        let page = Array(matchingCards.prefix(Self.localLearningItemPageSize))
        learningItems = StudyCardCatalogRepository.standaloneLearningItems(
            from: page,
            matching: ""
        )
        updateLocalLearningItemFallbackCursor(
            loadedCount: page.count,
            totalCount: matchingCards.count
        )
    }

    func restoreLocalLearningItemFallbackCursor(_ cursor: String?) {
        guard let cursor,
              cursor.hasPrefix(Self.localLearningItemCursorPrefix),
              Int(cursor.dropFirst(Self.localLearningItemCursorPrefix.count)) != nil
        else {
            learningItemsLocalFallbackOffset = nil
            learningItemsLocalFallbackIdentifiers = nil
            return
        }
        let lookup = StudyCardLookup(preferred: [], fallback: libraryCards)
        var seenIdentifiers = Set<String>()
        let loadedCards = learningItems.compactMap { item -> StudyCard? in
            guard let card = lookup.card(
                matching: [item.representativeCard.id, item.representativeCard.syncId]
            ) else { return nil }
            let identifiers = StudyCardIdentity.identifiers(for: card)
            guard seenIdentifiers.isDisjoint(with: identifiers) else { return nil }
            seenIdentifiers.formUnion(identifiers)
            return card
        }
        let remainingCards = libraryCards.filter { card in
            let identifiers = StudyCardIdentity.identifiers(for: card)
            guard seenIdentifiers.isDisjoint(with: identifiers) else { return false }
            seenIdentifiers.formUnion(identifiers)
            return true
        }
        let orderedCards = loadedCards + remainingCards
        learningItems = StudyCardCatalogRepository.standaloneLearningItems(
            from: loadedCards,
            matching: ""
        )
        learningItemsLocalFallbackIdentifiers = orderedCards.map {
            Array(StudyCardIdentity.identifiers(for: $0)).sorted()
        }
        updateLocalLearningItemFallbackCursor(
            loadedCount: loadedCards.count,
            totalCount: orderedCards.count
        )
    }

    private func loadMoreLocalLearningItems(
        offset: Int,
        userID: Int,
        query: String
    ) {
        isLoadingMoreLearningItems = true
        defer { isLoadingMoreLearningItems = false }
        guard activeUserID == userID,
              learningItemsQuery == query,
              learningItemsLocalFallbackOffset == offset
        else { return }
        guard let orderedIdentifiers = learningItemsLocalFallbackIdentifiers else {
            learningItemsLocalFallbackOffset = nil
            learningItemsNextCursor = nil
            return
        }
        let pageIdentifiers = Array(
            orderedIdentifiers
                .dropFirst(offset)
                .prefix(Self.localLearningItemPageSize)
        )
        let lookup = StudyCardLookup(preferred: [], fallback: libraryCards)
        let page = pageIdentifiers.compactMap { lookup.card(matching: $0) }
        learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
            StudyCardCatalogRepository.standaloneLearningItems(
                from: page,
                matching: ""
            ),
            to: learningItems
        )
        updateLocalLearningItemFallbackCursor(
            loadedCount: offset + pageIdentifiers.count,
            totalCount: orderedIdentifiers.count
        )
    }

    private func updateLocalLearningItemFallbackCursor(
        loadedCount: Int,
        totalCount: Int
    ) {
        guard loadedCount < totalCount else {
            learningItemsLocalFallbackOffset = nil
            learningItemsLocalFallbackIdentifiers = nil
            learningItemsNextCursor = nil
            return
        }
        learningItemsLocalFallbackOffset = loadedCount
        learningItemsNextCursor = Self.localLearningItemCursorPrefix + String(loadedCount)
    }

    func card(for item: StudyLearningItemCard) -> StudyCard? {
        let identifiers = [item.id, item.syncId]
        return allCards.first { StudyCardIdentity.matches($0, any: identifiers) }
            ?? libraryCards.first { StudyCardIdentity.matches($0, any: identifiers) }
    }

    func resolveCard(for item: StudyLearningItemCard) async throws -> StudyCard? {
        if let localCard = card(for: item) {
            return localCard
        }
        guard let userID = activeUserID else { return nil }
        let activationGeneration = accountActivationGeneration
        let canonicalCard = try await fetchCanonicalCard(id: item.syncId)
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if let canonicalCard {
            try upsertLocalCard(canonicalCard, markedDirty: false)
            try context.save()
            loadLibraryCards(userID: userID)
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                [canonicalCard],
                to: allCards
            )
        }
        return canonicalCard
    }

    func resolveCard(for item: StudyNewCardQueueItem) async throws -> StudyCard? {
        let identifiers = [item.id]
        if let localCard = allCards.first(where: {
            StudyCardIdentity.matches($0, any: identifiers)
        }) ?? libraryCards.first(where: {
            StudyCardIdentity.matches($0, any: identifiers)
        }) {
            return localCard
        }
        guard let userID = activeUserID else { return nil }
        let activationGeneration = accountActivationGeneration
        let canonicalCard = try await fetchCanonicalCard(id: item.id)
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if let canonicalCard {
            try upsertLocalCard(canonicalCard, markedDirty: false)
            try context.save()
            loadLibraryCards(userID: userID)
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                [canonicalCard],
                to: allCards
            )
        }
        return canonicalCard
    }

    func upsertAllCardsPresentation(
        _ card: StudyCard,
        addToLearningItemsIfMissing: Bool = false
    ) {
        allCards = StudyCardCatalogRepository.upserting(
            card,
            into: allCards,
            matching: allCardsQuery
        )
        reconcileLearningItems(
            upserting: card,
            addIfMissing: addToLearningItemsIfMissing
        )
    }

    func reconcileLearningItems(
        upserting card: StudyCard,
        addIfMissing: Bool = false
    ) {
        learningItems = reconciledLearningItems(
            learningItems,
            upserting: card,
            matching: learningItemsQuery,
            addIfMissing: addIfMissing
        )
    }

    private func reconciledLearningItems(
        _ sourceItems: [StudyLearningItem],
        upserting card: StudyCard,
        matching query: String,
        addIfMissing: Bool = false
    ) -> [StudyLearningItem] {
        var foundExistingCard = false
        var updatedItems = sourceItems.compactMap { item in
            let representativeCard = updatedLearningItemCard(
                item.representativeCard,
                from: card,
                foundExistingCard: &foundExistingCard
            )
            let stages = item.stages.map { stage in
                StudyLearningItemStage(
                    number: stage.number,
                    status: stage.status,
                    cardCount: stage.cardCount,
                    representativeCard: updatedLearningItemCard(
                        stage.representativeCard,
                        from: card,
                        foundExistingCard: &foundExistingCard
                    ),
                    cards: stage.cards.map {
                        updatedLearningItemCard(
                            $0,
                            from: card,
                            foundExistingCard: &foundExistingCard
                        )
                    }
                )
            }
            let updatedItem = StudyLearningItem(
                id: item.id,
                groupId: item.groupId,
                representativeCard: representativeCard,
                currentStageNumber: item.currentStageNumber,
                stageCount: item.stageCount,
                cardCount: item.cardCount,
                retiredStageCount: item.retiredStageCount,
                transferDemonstrated: item.transferDemonstrated,
                stages: stages
            )
            return learningItem(updatedItem, matches: query)
                ? updatedItem
                : nil
        }
        guard addIfMissing,
              !foundExistingCard,
              let standalone = StudyCardCatalogRepository.standaloneLearningItems(
                  from: [card],
                  matching: query
              ).first
        else { return updatedItems }
        // Keep optimistic/manual creations visible immediately. A later grouped
        // refresh replaces this projection if the server assigned the card to a family.
        updatedItems.insert(standalone, at: 0)
        return updatedItems
    }

    private func learningItem(_ item: StudyLearningItem, matches query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let cards = [item.representativeCard] + item.stages.flatMap(\.cards)
        return cards.contains {
            $0.displayText.localizedCaseInsensitiveContains(query)
                || ($0.meaning?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func reconcilePendingCardMutationsIntoLearningItems() {
        removeStandaloneItemsDuplicatedByFamilies()
        let pendingDeleteIdentifiers =
            (try? cardOutbox.pendingDeleteIdentifiers()) ?? []
        if !pendingDeleteIdentifiers.isEmpty {
            removeFromLearningItems(matching: pendingDeleteIdentifiers)
        }
        let pendingWriteIdentifiers =
            (try? cardOutbox.pendingWriteIdentifiers()) ?? []
        for card in libraryCards where StudyCardIdentity.matches(
            card,
            any: pendingWriteIdentifiers
        ) {
            reconcileLearningItems(upserting: card, addIfMissing: true)
        }
        removeStandaloneItemsDuplicatedByFamilies()
    }


    private func removeStandaloneItemsDuplicatedByFamilies() {
        let familyCardIdentifiers = Set(
            learningItems
                .filter { $0.groupId != nil }
                .flatMap { item in
                    [item.representativeCard] + item.stages.flatMap(\.cards)
                }
                .flatMap { [$0.id.lowercased(), $0.syncId.lowercased()] }
        )
        guard !familyCardIdentifiers.isEmpty else { return }
        learningItems.removeAll { item in
            item.groupId == nil
                && learningItemCard(
                    item.representativeCard,
                    matchesAny: familyCardIdentifiers
                )
        }
    }

    private func updatedLearningItemCard(
        _ itemCard: StudyLearningItemCard,
        from card: StudyCard,
        foundExistingCard: inout Bool
    ) -> StudyLearningItemCard {
        guard StudyCardIdentity.matches(card, any: [itemCard.id, itemCard.syncId]) else {
            return itemCard
        }
        foundExistingCard = true
        return StudyLearningItemCard(
            id: itemCard.id,
            syncId: itemCard.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            displayText: card.promptText,
            meaning: card.answerText,
            variantKind: itemCard.variantKind
        )
    }

    func removeFromLearningItems(_ card: StudyCard) {
        removeFromLearningItems(matching: Set([
            card.id.lowercased(),
            card.reviewCardID.lowercased(),
        ]))
    }

    private func removeFromLearningItems(matching identifiers: Set<String>) {
        learningItems = learningItemsRemoving(
            learningItems,
            removing: identifiers,
            matching: learningItemsQuery
        )
    }

    private func learningItemsRemoving(
        _ sourceItems: [StudyLearningItem],
        removing identifiers: Set<String>,
        matching query: String
    ) -> [StudyLearningItem] {
        sourceItems.compactMap { item in
            if item.groupId == nil {
                let isDeletedCard = learningItemCard(
                    item.representativeCard,
                    matchesAny: identifiers
                )
                return isDeletedCard ? nil : item
            }
            let stages = item.stages.compactMap { stage -> StudyLearningItemStage? in
                let cards = stage.cards.filter {
                    !learningItemCard($0, matchesAny: identifiers)
                }
                guard !cards.isEmpty else { return nil }
                let representativeCard = learningItemCard(
                    stage.representativeCard,
                    matchesAny: identifiers
                ) ? cards[0] : stage.representativeCard
                return StudyLearningItemStage(
                    number: stage.number,
                    status: stage.status,
                    cardCount: cards.count,
                    representativeCard: representativeCard,
                    cards: cards
                )
            }
            guard !stages.isEmpty else { return nil }
            let representativeCard = learningItemCard(
                item.representativeCard,
                matchesAny: identifiers
            ) ? stages[0].representativeCard : item.representativeCard
            let currentStageNumber = item.currentStageNumber.flatMap { currentNumber in
                stages.contains { $0.number == currentNumber } ? currentNumber : nil
            } ?? stages.first(where: { $0.status == .available })?.number
            let updatedItem = StudyLearningItem(
                id: item.id,
                groupId: item.groupId,
                representativeCard: representativeCard,
                currentStageNumber: currentStageNumber,
                stageCount: stages.count,
                cardCount: stages.reduce(0) { $0 + $1.cardCount },
                retiredStageCount: stages.filter { $0.status == .retired }.count,
                transferDemonstrated: item.transferDemonstrated,
                stages: stages
            )
            return learningItem(updatedItem, matches: query)
                ? updatedItem
                : nil
        }
    }

    func reconcileCachedDefaultLearningItems(upserting card: StudyCard) {
        guard let snapshot = cardCatalogSnapshot else { return }
        replaceCachedDefaultLearningItems(
            in: snapshot,
            with: reconciledLearningItems(
                snapshot.learningItems,
                upserting: card,
                matching: ""
            )
        )
    }

    func removeFromCachedDefaultLearningItems(_ card: StudyCard) {
        guard let snapshot = cardCatalogSnapshot else { return }
        replaceCachedDefaultLearningItems(
            in: snapshot,
            with: learningItemsRemoving(
                snapshot.learningItems,
                removing: Set([
                    card.id.lowercased(),
                    card.reviewCardID.lowercased(),
                ]),
                matching: ""
            )
        )
    }

    private func replaceCachedDefaultLearningItems(
        in snapshot: StudyCardCatalogSnapshot,
        with learningItems: [StudyLearningItem]
    ) {
        cardCatalogSnapshot = StudyCardCatalogSnapshot(
            savedAt: snapshot.savedAt,
            newCardQueue: snapshot.newCardQueue,
            newCardQueueTotal: snapshot.newCardQueueTotal,
            newCardQueueNextCursor: snapshot.newCardQueueNextCursor,
            newCardQueueRefreshedAt: snapshot.newCardQueueRefreshedAt,
            learningItems: learningItems,
            learningItemsNextCursor: snapshot.learningItemsNextCursor,
            learningItemsRefreshedAt: snapshot.learningItemsRefreshedAt
        )
    }

    private func learningItemCard(
        _ card: StudyLearningItemCard,
        matchesAny identifiers: Set<String>
    ) -> Bool {
        identifiers.contains(card.id.lowercased())
            || identifiers.contains(card.syncId.lowercased())
    }

}

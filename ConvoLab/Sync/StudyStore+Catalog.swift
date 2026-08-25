import Foundation
import SwiftData

extension StudyStore {
    func refreshNewCardQueue() async throws {
        guard let userID = activeUserID else { return }
        newCardQueueRefreshRevision += 1
        let refreshRevision = newCardQueueRefreshRevision
        isRefreshingNewCardQueue = true
        defer {
            if activeUserID == userID, newCardQueueRefreshRevision == refreshRevision {
                isRefreshingNewCardQueue = false
            }
        }

        let response = try await cardCatalogRepository.newCardQueuePage()
        guard activeUserID == userID, newCardQueueRefreshRevision == refreshRevision else {
            return
        }
        newCardQueue = StudyCardCatalogRepository.appendingUniqueQueueItems(
            response.items,
            to: []
        )
        newCardQueueTotal = response.total
        newCardQueueNextCursor = response.nextCursor
    }

    func loadMoreNewCardQueue() async throws {
        guard
            let userID = activeUserID,
            let cursor = newCardQueueNextCursor,
            !isRefreshingNewCardQueue,
            !isLoadingMoreNewCardQueue,
            newCardQueueReorderToken == nil
        else { return }
        let refreshRevision = newCardQueueRefreshRevision
        isLoadingMoreNewCardQueue = true
        defer {
            if activeUserID == userID {
                isLoadingMoreNewCardQueue = false
            }
        }

        let response = try await cardCatalogRepository.newCardQueuePage(after: cursor)
        guard
            activeUserID == userID,
            newCardQueueRefreshRevision == refreshRevision,
            newCardQueueNextCursor == cursor
        else { return }
        newCardQueue = StudyCardCatalogRepository.appendingUniqueQueueItems(
            response.items,
            to: newCardQueue
        )
        newCardQueueTotal = response.total
        newCardQueueNextCursor = response.nextCursor
    }

    func refreshAllCards(search query: String = "") async throws {
        guard let userID = activeUserID else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        allCardsRefreshRevision += 1
        let refreshRevision = allCardsRefreshRevision
        allCardsQuery = trimmedQuery
        allCardsNextCursor = nil
        isRefreshingAllCards = true
        defer {
            if activeUserID == userID, allCardsRefreshRevision == refreshRevision {
                isRefreshingAllCards = false
            }
        }

        do {
            let response = try await cardCatalogRepository.cardPage(matching: trimmedQuery)
            guard
                activeUserID == userID,
                allCardsRefreshRevision == refreshRevision,
                allCardsQuery == trimmedQuery
            else { return }
            allCards = StudyCardCatalogRepository.appendingUniqueCards(
                response.items,
                to: []
            )
            allCardsNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                allCardsRefreshRevision == refreshRevision,
                allCardsQuery == trimmedQuery
            else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            // SwiftData remains the offline source of truth for browsing. The
            // server list is only the paginated presentation when reachable.
            allCards = StudyCardCatalogRepository.cards(
                libraryCards,
                matching: trimmedQuery
            )
            allCardsNextCursor = nil
            throw error
        }
    }

    func loadMoreAllCards() async throws {
        guard
            let userID = activeUserID,
            let cursor = allCardsNextCursor,
            !isRefreshingAllCards,
            !isLoadingMoreAllCards
        else { return }
        let refreshRevision = allCardsRefreshRevision
        isLoadingMoreAllCards = true
        defer {
            if activeUserID == userID {
                isLoadingMoreAllCards = false
            }
        }

        let query = allCardsQuery
        let response = try await cardCatalogRepository.cardPage(
            matching: query,
            after: cursor
        )
        guard
            activeUserID == userID,
            allCardsRefreshRevision == refreshRevision,
            allCardsNextCursor == cursor,
            allCardsQuery == query
        else { return }
        allCards = StudyCardCatalogRepository.appendingUniqueCards(
            response.items,
            to: allCards
        )
        allCardsNextCursor = response.nextCursor
    }

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
            reconcilePendingCardMutationsIntoLearningItems()
            learningItemsNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                learningItemsRefreshRevision == refreshRevision,
                learningItemsQuery == trimmedQuery
            else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            learningItems = StudyCardCatalogRepository.standaloneLearningItems(
                from: libraryCards,
                matching: trimmedQuery
            )
            learningItemsNextCursor = nil
            throw error
        }
    }

    func loadMoreLearningItems() async throws {
        guard
            let userID = activeUserID,
            let cursor = learningItemsNextCursor,
            !isRefreshingLearningItems,
            !isLoadingMoreLearningItems
        else { return }
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
        reconcilePendingCardMutationsIntoLearningItems()
        learningItemsNextCursor = response.nextCursor
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
        var foundExistingCard = false
        learningItems = learningItems.compactMap { item in
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
            return learningItem(updatedItem, matches: learningItemsQuery)
                ? updatedItem
                : nil
        }
        guard addIfMissing,
              !foundExistingCard,
              let standalone = StudyCardCatalogRepository.standaloneLearningItems(
                  from: [card],
                  matching: learningItemsQuery
              ).first
        else { return }
        // Keep optimistic/manual creations visible immediately. A later grouped
        // refresh replaces this projection if the server assigned the card to a family.
        learningItems.insert(standalone, at: 0)
    }

    private func learningItem(_ item: StudyLearningItem, matches query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let cards = [item.representativeCard] + item.stages.flatMap(\.cards)
        return cards.contains {
            $0.displayText.localizedCaseInsensitiveContains(query)
                || ($0.meaning?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func reconcilePendingCardMutationsIntoLearningItems() {
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
        learningItems = learningItems.compactMap { item in
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
            return learningItem(updatedItem, matches: learningItemsQuery)
                ? updatedItem
                : nil
        }
    }

    private func learningItemCard(
        _ card: StudyLearningItemCard,
        matchesAny identifiers: Set<String>
    ) -> Bool {
        identifiers.contains(card.id.lowercased())
            || identifiers.contains(card.syncId.lowercased())
    }

    func moveNewCards(fromOffsets: IndexSet, toOffset: Int) async throws {
        guard
            let userID = activeUserID,
            !fromOffsets.isEmpty,
            !isRefreshingNewCardQueue,
            !isLoadingMoreNewCardQueue,
            newCardQueueReorderToken == nil
        else { return }
        let reorderToken = UUID()
        newCardQueueReorderToken = reorderToken
        defer {
            if newCardQueueReorderToken == reorderToken {
                newCardQueueReorderToken = nil
            }
        }
        let refreshRevision = newCardQueueRefreshRevision
        let previousItems = newCardQueue
        newCardQueue.move(fromOffsets: fromOffsets, toOffset: toOffset)

        do {
            let response = try await cardCatalogRepository.reorderNewCards(
                newCardQueue.map(\.id)
            )
            guard
                activeUserID == userID,
                newCardQueueRefreshRevision == refreshRevision
            else { return }
            newCardQueue = response.items
            newCardQueueTotal = response.total
            newCardQueueNextCursor = response.nextCursor
        } catch {
            guard
                activeUserID == userID,
                newCardQueueRefreshRevision == refreshRevision
            else { return }
            newCardQueue = previousItems
            throw error
        }
    }

}

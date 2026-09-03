import Foundation
import SwiftData

extension StudyStore {
    func createLessonFollowupCohort(
        id: String,
        cardIDs: [String],
        label: String?
    ) async throws -> StudyIntroductionCohort {
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let cohort = try await cardCatalogRepository.createLessonFollowupCohort(
            id: id,
            cardIDs: cardIDs,
            label: label
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        return cohort
    }

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
        newCardQueueRefreshedAt = .now
        reconcilePendingCardMutationsIntoNewCardQueue()
        persistCardCatalogSnapshot()
    }

    func refreshNewCardQueueIfNeeded(maxAge: TimeInterval = 60) async throws {
        guard !isFresh(newCardQueueRefreshedAt, maxAge: maxAge) else { return }
        try await refreshNewCardQueue()
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
        reconcilePendingCardMutationsIntoNewCardQueue()
        persistCardCatalogSnapshot()
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

    func reconcilePendingCardMutationsIntoNewCardQueue() {
        let pendingDeleteIdentifiers =
            (try? cardOutbox.pendingDeleteIdentifiers()) ?? []
        let previousCount = newCardQueue.count
        newCardQueue.removeAll { item in
            pendingDeleteIdentifiers.contains(item.id.lowercased())
        }
        let removedCount = previousCount - newCardQueue.count
        if removedCount > 0 {
            newCardQueueTotal = max(
                newCardQueue.count,
                newCardQueueTotal - removedCount
            )
        }

        let pendingWriteIdentifiers =
            (try? cardOutbox.pendingWriteIdentifiers()) ?? []
        guard !pendingWriteIdentifiers.isEmpty else { return }
        newCardQueue = newCardQueue.map { item in
            guard let card = libraryCards.first(where: {
                StudyCardIdentity.matches($0, any: [item.id])
            }), StudyCardIdentity.matches(card, any: pendingWriteIdentifiers)
            else { return item }
            return StudyNewCardQueueItem(
                id: item.id,
                noteId: card.noteId ?? item.noteId,
                cardType: card.cardType,
                displayText: card.promptText,
                meaning: card.answerText,
                queuePosition: item.queuePosition,
                createdAt: item.createdAt,
                updatedAt: card.updatedAt
            )
        }
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
            newCardQueueRefreshedAt = .now
            reconcilePendingCardMutationsIntoNewCardQueue()
            persistCardCatalogSnapshot()
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

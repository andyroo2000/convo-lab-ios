import Foundation
import SwiftData

extension StudyStore {
    private var nextOfflineDueAt: Date? {
        StudySessionPolicy.nextOfflineDueAt(
            activeCards: cards,
            libraryCards: libraryCards
        )
    }

    func refreshOfflineReserve(
        userID: Int,
        activationGeneration: Int,
        clearingOtherRecords: Bool
    ) async throws {
        let reserve: StudyOfflineReserve = try await api.request(
            "/api/study/offline-reserve",
            method: "POST"
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        let preservingActiveReviewQueue = lessonSessionIsPresented
        let persistedActiveCards = preservingActiveReviewQueue
            ? try localCardRepository.activeCards(userID: userID)
            : []
        try localCardRepository.mergeOfflineReserve(
            reserve.cards,
            userID: userID,
            preservingActiveSessionOrder: preservingActiveReviewQueue
        )
        offlineReserveMetadata = reserve.metadata
        cardCatalogSnapshotCache?.saveOfflineReserveMetadata(reserve.metadata, userID: userID)
        loadLibraryCards(userID: userID)
        scheduleNextOfflineActivation()
        await mediaCache.prepare(
            urls: reserve.cards.flatMap(\.mediaURLs),
            category: "offline-study"
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else { return }
        markPrepared(
            cards: cards + reserve.cards + persistedActiveCards,
            clearingOtherRecords: clearingOtherRecords
        )
    }

    func activateOfflineDueCards(
        at date: Date? = nil,
        preservingCurrentOrder: Bool = true
    ) {
        guard let userID = activeUserID, !lessonSessionIsPresented else { return }
        let newlyDueCards = newlyDueOfflineCards(
            at: date ?? dueActivationScheduler.now,
            pendingDeleteIDs: (try? cardOutbox.pendingDeleteIdentifiers()) ?? [],
            inactiveRecordsByIdentifier: inactiveOfflineRecords(userID: userID)
        )
        if !newlyDueCards.isEmpty {
            publishOfflineDueCards(
                newlyDueCards,
                preservingCurrentOrder: preservingCurrentOrder
            )
        }
        scheduleNextOfflineActivation()
    }

    private func inactiveOfflineRecords(
        userID: Int
    ) -> [String: LocalCardRecord] {
        let records = (try? context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && !$0.isInActiveSession
                },
                sortBy: [SortDescriptor(\.normalizedID), SortDescriptor(\.id)]
            )
        )) ?? []
        var recordsByIdentifier: [String: LocalCardRecord] = [:]
        for record in records {
            for identifier in [record.normalizedID, record.syncID]
            where !identifier.isEmpty && recordsByIdentifier[identifier] == nil {
                recordsByIdentifier[identifier] = record
            }
        }
        return recordsByIdentifier
    }

    private func newlyDueOfflineCards(
        at activationDate: Date,
        pendingDeleteIDs: Set<String>,
        inactiveRecordsByIdentifier: [String: LocalCardRecord]
    ) -> [StudyCard] {
        var activeCardIdentifiers = cards.reduce(into: Set<String>()) {
            $0.formUnion(StudyCardIdentity.identifiers(for: $1))
        }
        var newlyDueCards: [StudyCard] = []
        for card in libraryCards {
            guard
                !StudyCardIdentity.matches(card, any: pendingDeleteIDs),
                card.isEligibleForOfflineStudy(at: activationDate)
            else {
                continue
            }
            let identifiers = StudyCardIdentity.identifiers(for: card)
            guard
                activeCardIdentifiers.isDisjoint(with: identifiers),
                let record = identifiers.lazy.compactMap({
                    inactiveRecordsByIdentifier[$0]
                }).first
            else {
                continue
            }
            activeCardIdentifiers.formUnion(identifiers)
            newlyDueCards.append(card)
            record.isInActiveSession = true
        }
        return newlyDueCards
    }

    private func publishOfflineDueCards(
        _ newlyDueCards: [StudyCard],
        preservingCurrentOrder: Bool
    ) {
        let orderedNewCards = StudySessionPolicy.offlineOrderedCards(newlyDueCards)
        cards = preservingCurrentOrder
            ? cards + orderedNewCards
            : StudySessionPolicy.offlineOrderedCards(cards + orderedNewCards)
        do {
            try context.save()
        } catch {
            handleSyncError(error)
        }
    }

    func scheduleNextOfflineActivation() {
        dueActivationScheduler.cancel()
        guard !lessonSessionIsPresented, let dueAt = nextOfflineDueAt else {
            return
        }
        dueActivationScheduler.schedule(at: dueAt) { [weak self, dueActivationScheduler] in
            self?.activateOfflineDueCards(at: dueActivationScheduler.now)
        }
    }
}

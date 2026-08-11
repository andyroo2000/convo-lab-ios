import Foundation
import SwiftData

@MainActor
final class CardSyncFeedRepository {
    enum PullResult: Equatable {
        case completed
        case checkpointReset
        case discardedStaleResponse
    }

    enum RepositoryError: LocalizedError {
        case invalidPage(String)
        case uncommittedLocalChanges

        var errorDescription: String? {
            switch self {
            case let .invalidPage(reason):
                "The card sync feed returned an invalid page: \(reason)"
            case .uncommittedLocalChanges:
                "Card sync paused because local persistence has uncommitted changes."
            }
        }
    }

    private struct Activation: Equatable {
        let userID: Int
        let generation: Int
    }

    private enum ResolvedEntry {
        case upsert(StudyCard)
        case delete(resourceID: String)
    }

    private struct ResolvedPage {
        let entries: [ResolvedEntry]
        let usedIndividualResolution: Bool
    }

    private struct StaleActivationError: Error {}

    private let api: APIClient
    private let context: ModelContext
    private let beforeApplyingEntry: (Int) throws -> Void
    private var activeUserID: Int?
    private var generation = 0

    init(
        api: APIClient,
        context: ModelContext,
        beforeApplyingEntry: @escaping (Int) throws -> Void = { _ in }
    ) {
        self.api = api
        self.context = context
        self.beforeApplyingEntry = beforeApplyingEntry
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        generation += 1
        activeUserID = userID
    }

    func deactivate() {
        generation += 1
        activeUserID = nil
    }

    func pullChanges() async throws -> PullResult {
        guard let activeUserID else { return .completed }
        try ensureCleanContext()
        let activation = Activation(userID: activeUserID, generation: generation)
        var checkpoint = try syncState(userID: activeUserID).cardCheckpoint

        do {
            while true {
                let page: SyncFeedPage = try await api.request(
                    "/api/sync/feed",
                    query: [
                        URLQueryItem(name: "domain", value: "flashcards"),
                        URLQueryItem(name: "resource_type", value: "card"),
                        URLQueryItem(name: "after_checkpoint", value: String(checkpoint)),
                        URLQueryItem(name: "per_page", value: "50"),
                    ]
                )
                try ensureActive(activation)
                try validate(page, after: checkpoint)
                let resolvedPage = try await resolve(page.data, activation: activation)
                try ensureActive(activation)
                try commit(
                    resolvedPage.entries,
                    checkpoint: page.meta.nextCheckpoint,
                    activation: activation
                )
                checkpoint = page.meta.nextCheckpoint

                // A partial-but-successful batch response is anomalous. Resolve
                // at most this page and leave later pages for the next sync.
                if resolvedPage.usedIndividualResolution {
                    return .completed
                }
                guard page.meta.hasMore else { return .completed }
            }
        } catch is StaleActivationError {
            return .discardedStaleResponse
        } catch APIClientError.rejected(status: 409, message: _) {
            do {
                try ensureActive(activation)
                try resetServerBackedCards(activation: activation)
                return .checkpointReset
            } catch is StaleActivationError {
                return .discardedStaleResponse
            }
        }
    }

    private func validate(_ page: SyncFeedPage, after checkpoint: Int64) throws {
        guard page.meta.nextCheckpoint >= checkpoint else {
            throw RepositoryError.invalidPage("the next checkpoint moved backward")
        }
        guard !page.meta.hasMore || page.meta.nextCheckpoint > checkpoint else {
            throw RepositoryError.invalidPage("a paginated page did not advance the checkpoint")
        }

        var previousCheckpoint = checkpoint
        for entry in page.data {
            guard ["create", "update", "delete"].contains(entry.operation) else {
                throw RepositoryError.invalidPage("unsupported operation \(entry.operation)")
            }
            guard entry.checkpoint > previousCheckpoint else {
                throw RepositoryError.invalidPage("entry checkpoints were not strictly increasing")
            }
            guard entry.checkpoint <= page.meta.nextCheckpoint else {
                throw RepositoryError.invalidPage("an entry exceeded the page checkpoint")
            }
            previousCheckpoint = entry.checkpoint
        }
    }

    private func resolve(
        _ entries: [SyncFeedPage.Entry],
        activation: Activation
    ) async throws -> ResolvedPage {
        var requestedCardIDs: [String] = []
        var seenCardIDs: Set<String> = []
        for entry in entries where entry.operation != "delete" {
            let normalizedID = entry.resourceId.lowercased()
            if seenCardIDs.insert(normalizedID).inserted {
                requestedCardIDs.append(entry.resourceId)
            }
        }

        let serverCards: [StudyCard]
        if requestedCardIDs.isEmpty {
            serverCards = []
        } else {
            let response: StudyCardBatchResponse = try await api.request(
                "/api/study/cards/batch",
                method: "POST",
                body: StudyCardBatchRequest(ids: requestedCardIDs)
            )
            try ensureActive(activation)
            serverCards = response.cards
        }

        var cardsByID: [String: StudyCard] = [:]
        for card in serverCards {
            for identifier in cardIdentifiers(for: card) where cardsByID[identifier] == nil {
                cardsByID[identifier] = card
            }
        }

        var resolvedEntries: [ResolvedEntry] = []
        var usedIndividualResolution = false
        for entry in entries {
            try ensureActive(activation)
            if entry.operation == "delete" {
                resolvedEntries.append(.delete(resourceID: entry.resourceId))
                continue
            }

            let normalizedID = entry.resourceId.lowercased()
            if let card = cardsByID[normalizedID] {
                resolvedEntries.append(.upsert(card))
                continue
            }

            usedIndividualResolution = true
            do {
                let card: StudyCard = try await api.request(
                    "/api/study/cards/\(entry.resourceId)"
                )
                try ensureActive(activation)
                resolvedEntries.append(.upsert(card))
            } catch APIClientError.rejected(status: 404, message: _) {
                try ensureActive(activation)
                resolvedEntries.append(.delete(resourceID: entry.resourceId))
            }
        }
        return ResolvedPage(
            entries: resolvedEntries,
            usedIndividualResolution: usedIndividualResolution
        )
    }

    private func commit(
        _ entries: [ResolvedEntry],
        checkpoint: Int64,
        activation: Activation
    ) throws {
        try performTransaction {
            try ensureActive(activation)
            for (index, entry) in entries.enumerated() {
                try beforeApplyingEntry(index)
                try ensureActive(activation)
                switch entry {
                case let .upsert(card):
                    try upsert(card, userID: activation.userID)
                case let .delete(resourceID):
                    try removeServerCard(resourceID: resourceID, userID: activation.userID)
                }
            }
            let state = try syncState(userID: activation.userID, savingIfCreated: false)
            state.cardCheckpoint = checkpoint
            state.updatedAt = .now
        }
    }

    private func upsert(_ serverCard: StudyCard, userID: Int) throws {
        let serverID = serverCard.id
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.id == serverID }
        )
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        let localCard = try record.flatMap {
            try StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
        var identifiers = Set(cardIdentifiers(for: serverCard))
        if let localCard {
            identifiers.formUnion(cardIdentifiers(for: localCard))
        }
        if let record {
            identifiers.insert(record.id.lowercased())
        }
        let pending = try pendingMutations(userID: userID, matching: identifiers)
        // A local delete is authoritative until its outbox item is acknowledged.
        // Recreating the row from the feed would make the deleted card visible
        // in the library while that retry is still pending.
        guard !pending.contains(where: { $0.kind == "cardDelete" }) else { return }
        let hasPendingReview = pending.contains {
            $0.kind == "review" && $0.lastError == nil
        }
        let preservesLocalContent = record?.locallyUpdatedAt != nil || pending.contains {
            $0.kind == "cardCreate" || $0.kind == "cardUpdate"
        }
        let merged = mergedCard(
            serverCard,
            localCard: localCard,
            preservingPendingReview: hasPendingReview,
            preservingLocalContent: preservesLocalContent
        )
        let payload = try StorageCodec.encoder.encode(merged)

        if let record {
            record.payload = payload
            record.serverUpdatedAt = serverCard.updatedAt
            if preservesLocalContent, record.locallyUpdatedAt == nil {
                record.locallyUpdatedAt = .now
            } else if !preservesLocalContent {
                record.locallyUpdatedAt = nil
            }
        } else {
            let queueIndex = try context.fetch(
                FetchDescriptor<LocalCardRecord>(
                    predicate: #Predicate { $0.userID == userID && $0.isInActiveSession }
                )
            ).count
            let record = LocalCardRecord(
                card: merged,
                userID: userID,
                queueIndex: queueIndex,
                payload: payload
            )
            record.serverUpdatedAt = serverCard.updatedAt
            record.locallyUpdatedAt = preservesLocalContent ? .now : nil
            context.insert(record)
        }
    }

    private func mergedCard(
        _ serverCard: StudyCard,
        localCard: StudyCard?,
        preservingPendingReview: Bool,
        preservingLocalContent: Bool
    ) -> StudyCard {
        guard let localCard, preservingPendingReview || preservingLocalContent else {
            return serverCard
        }
        return StudyCard(
            id: serverCard.id,
            syncId: serverCard.syncId ?? localCard.syncId,
            noteId: serverCard.noteId,
            cardType: serverCard.cardType,
            prompt: preservingLocalContent ? localCard.prompt : serverCard.prompt,
            answer: preservingLocalContent ? localCard.answer : serverCard.answer,
            state: preservingPendingReview ? localCard.state : serverCard.state,
            answerAudioSource: serverCard.answerAudioSource,
            createdAt: serverCard.createdAt,
            updatedAt: preservingPendingReview || preservingLocalContent
                ? localCard.updatedAt
                : serverCard.updatedAt
        )
    }

    private func removeServerCard(resourceID: String, userID: Int) throws {
        let normalizedResourceID = resourceID.lowercased()
        let records = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        for record in records {
            let identifiers = try identifiers(for: record)
            guard identifiers.contains(normalizedResourceID) else { continue }
            guard try pendingMutations(userID: userID, matching: identifiers).isEmpty else {
                continue
            }
            context.delete(record)
        }
    }

    private func resetServerBackedCards(activation: Activation) throws {
        let userID = activation.userID
        try performTransaction {
            try ensureActive(activation)
            let records = try context.fetch(
                FetchDescriptor<LocalCardRecord>(
                    predicate: #Predicate { $0.userID == userID }
                )
            )
            for record in records where record.locallyUpdatedAt == nil {
                let identifiers = try identifiers(for: record)
                if try pendingMutations(
                    userID: userID,
                    matching: identifiers
                ).isEmpty {
                    context.delete(record)
                }
            }
            let state = try syncState(userID: userID, savingIfCreated: false)
            state.cardCheckpoint = 0
            state.updatedAt = .now
        }
    }

    private func identifiers(for record: LocalCardRecord) throws -> Set<String> {
        var identifiers = Set([record.id.lowercased()])
        if let card = try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload) {
            identifiers.formUnion(cardIdentifiers(for: card))
        }
        return identifiers
    }

    private func cardIdentifiers(for card: StudyCard) -> [String] {
        [card.id, card.reviewCardID].map { $0.lowercased() }
    }

    private func pendingMutations(
        userID: Int,
        matching identifiers: Set<String>
    ) throws -> [PendingMutation] {
        try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate"
                            || $0.kind == "cardUpdate"
                            || $0.kind == "cardDelete"
                            || $0.kind == "review")
                }
            )
        ).filter { identifiers.contains($0.resourceID.lowercased()) }
    }

    private func syncState(
        userID: Int,
        savingIfCreated: Bool = true
    ) throws -> LocalSyncState {
        var descriptor = FetchDescriptor<LocalSyncState>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        if let state = try context.fetch(descriptor).first {
            return state
        }
        let state = LocalSyncState(userID: userID)
        context.insert(state)
        if savingIfCreated {
            try context.save()
        }
        return state
    }

    private func ensureActive(_ activation: Activation) throws {
        guard
            activeUserID == activation.userID,
            generation == activation.generation
        else {
            throw StaleActivationError()
        }
    }

    private func performTransaction(_ changes: () throws -> Void) throws {
        // rollback() is context-wide, so never start a feed transaction while
        // another feature has uncommitted work in this shared ModelContext.
        try ensureCleanContext()
        do {
            try context.transaction(block: changes)
        } catch {
            // ModelContext keeps failed transaction mutations registered until
            // explicitly rolled back. Clear them so a later save cannot persist
            // a subset of a feed page without its checkpoint.
            context.rollback()
            throw error
        }
    }

    private func ensureCleanContext() throws {
        guard !context.hasChanges else {
            throw RepositoryError.uncommittedLocalChanges
        }
    }
}

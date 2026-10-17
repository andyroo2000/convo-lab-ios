import Foundation
import SwiftData

@MainActor
final class CardSyncFeedRepository {
    struct CommittedPageChanges: Equatable {
        struct RestoredCard: Equatable {
            let card: StudyCard
            let identifiers: Set<String>
        }

        let deletedCardIdentifiers: Set<String>
        let restoredCards: [RestoredCard]
    }

    enum PullResult: Equatable {
        case completed(deletedCardIdentifiers: Set<String>)
        case checkpointReset(deletedCardIdentifiers: Set<String>)
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

    private struct AppliedUpsert {
        let record: LocalCardRecord
        let card: StudyCard
        let identifiers: Set<String>
        let absorbedIdentifiers: Set<String>
    }

    private struct CommitResult {
        let deletedCardIdentifiers: Set<String>
        let appliedUpserts: [AppliedUpsert]
    }

    enum CommitQuery {
        case pendingMutations
        case activeCardCount
    }

    private struct CommitState {
        let pendingByIdentifier: [String: [PendingMutation]]
        var activeCardCount: Int

        func pending(matching identifiers: Set<String>) -> [PendingMutation] {
            identifiers.flatMap { pendingByIdentifier[$0] ?? [] }
        }
    }

    private struct PreparedUpsert {
        let serverCard: StudyCard
        let card: StudyCard
        let existingRecord: LocalCardRecord?
        let matchingRecords: [LocalCardRecord]
        let pending: [PendingMutation]
        let identifiers: Set<String>
        let preservesLocalContent: Bool
    }

    private struct RemovedRecord {
        let record: LocalCardRecord
        let identifiers: Set<String>
    }

    private struct RecordIndex {
        var recordsByIdentifier: [String: [LocalCardRecord]] = [:]
        var loadedIdentifiers: Set<String> = []
        var indexedRecordIDs: Set<PersistentIdentifier> = []
    }

    private struct StaleActivationError: Error {}

    nonisolated private final class SaveRevision: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    nonisolated private final class SaveObserver: @unchecked Sendable {
        private let token: NSObjectProtocol

        init(
            context: ModelContext,
            revision: SaveRevision,
            relevantEntityNames: Set<String>
        ) {
            token = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: context,
                queue: nil
            ) { notification in
                guard Self.affectsReconciliation(
                    notification,
                    relevantEntityNames: relevantEntityNames
                ) else { return }
                revision.increment()
            }
        }

        private static func affectsReconciliation(
            _ notification: Notification,
            relevantEntityNames: Set<String>
        ) -> Bool {
            guard let userInfo = notification.userInfo else { return true }
            let values = [
                ModelContext.NotificationKey.insertedIdentifiers,
                .updatedIdentifiers,
                .deletedIdentifiers,
                .invalidatedAllIdentifiers,
            ].map { userInfo[$0.rawValue] }
            if values.contains(where: { $0 as? Bool == true }) { return true }
            let collections = values.compactMap(identifierCollection)
            // Unknown notification payloads must invalidate conservatively.
            if collections.isEmpty { return true }
            return collections.joined().contains {
                relevantEntityNames.contains($0.entityName)
            }
        }

        private static func identifierCollection(_ value: Any?) -> [PersistentIdentifier]? {
            if let identifiers = value as? [PersistentIdentifier] { return identifiers }
            if let identifiers = value as? Set<PersistentIdentifier> { return Array(identifiers) }
            return nil
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private let api: APIClient
    private let context: ModelContext
    private let beforeApplyingEntry: (Int) throws -> Void
    private let onIndexingRecord: () -> Void
    private let onCommitQuery: (CommitQuery) -> Void
    private let saveRevision: SaveRevision
    private let saveObserver: SaveObserver
    private var activeUserID: Int?
    private var generation = 0
    private var cachedRecordsUserID: Int?
    private var cachedRecordIndex: RecordIndex?
    private var cachedAtSaveRevision: Int?

    init(
        api: APIClient,
        context: ModelContext,
        beforeApplyingEntry: @escaping (Int) throws -> Void = { _ in },
        onIndexingRecord: @escaping () -> Void = {},
        onCommitQuery: @escaping (CommitQuery) -> Void = { _ in }
    ) {
        self.api = api
        self.context = context
        self.beforeApplyingEntry = beforeApplyingEntry
        self.onIndexingRecord = onIndexingRecord
        self.onCommitQuery = onCommitQuery
        let saveRevision = SaveRevision()
        self.saveRevision = saveRevision
        saveObserver = SaveObserver(
            context: context,
            revision: saveRevision,
            relevantEntityNames: [
                Schema.entityName(for: LocalCardRecord.self),
                Schema.entityName(for: PendingMutation.self),
            ]
        )
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        generation += 1
        activeUserID = userID
        clearCachedRecords()
    }

    func deactivate() {
        generation += 1
        activeUserID = nil
        clearCachedRecords()
    }

    func pullChanges(
        onPageCommitted: (CommittedPageChanges) -> Void = { _ in }
    ) async throws -> PullResult {
        guard let activeUserID else { return .completed(deletedCardIdentifiers: []) }
        try ensureCleanContext()
        let activation = Activation(userID: activeUserID, generation: generation)
        var checkpoint = try syncState(userID: activeUserID).cardCheckpoint
        var deletedCardIdentifiers: Set<String> = []
        let startingSaveRevision = saveRevision.current
        var recordIndex: RecordIndex?
        var indexedAtSaveRevision: Int?
        if cachedRecordsUserID == activeUserID,
           cachedAtSaveRevision == startingSaveRevision {
            recordIndex = cachedRecordIndex
            indexedAtSaveRevision = cachedAtSaveRevision
        } else {
            clearCachedRecords()
        }

        do {
            while true {
                try ensureActive(activation)
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
                let currentSaveRevision = saveRevision.current
                if indexedAtSaveRevision != nil,
                   indexedAtSaveRevision != currentSaveRevision {
                    recordIndex = nil
                    indexedAtSaveRevision = nil
                    clearCachedRecords()
                }
                let previouslyDeletedCardIdentifiers = deletedCardIdentifiers
                let commitResult = try commit(
                    resolvedPage.entries,
                    checkpoint: page.meta.nextCheckpoint,
                    activation: activation,
                    deletedCardIdentifiers: deletedCardIdentifiers,
                    recordIndex: &recordIndex
                )
                if recordIndex != nil {
                    indexedAtSaveRevision = saveRevision.current
                    cachedRecordsUserID = activation.userID
                    cachedRecordIndex = recordIndex
                    cachedAtSaveRevision = indexedAtSaveRevision
                }
                deletedCardIdentifiers = commitResult.deletedCardIdentifiers
                // The checkpoint is durable now. Publish its deletions/aliases even
                // if cancellation arrived during the final synchronous save.
                try ensureCurrentActivation(activation)
                let restoredCardIdentifiers = previouslyDeletedCardIdentifiers.subtracting(
                    deletedCardIdentifiers
                )
                var unmatchedRestoredIdentifiers = restoredCardIdentifiers
                var restoredCards: [CommittedPageChanges.RestoredCard] = []
                for applied in commitResult.appliedUpserts.reversed()
                where !unmatchedRestoredIdentifiers.isDisjoint(with: applied.identifiers) {
                    restoredCards.append(
                        CommittedPageChanges.RestoredCard(
                            card: applied.card,
                            identifiers: applied.identifiers
                        )
                    )
                    unmatchedRestoredIdentifiers.subtract(applied.identifiers)
                }
                let absorbedIdentifiers = commitResult.appliedUpserts.reduce(into: Set<String>()) {
                    $0.formUnion($1.absorbedIdentifiers)
                }
                for applied in commitResult.appliedUpserts
                where !applied.absorbedIdentifiers.isEmpty
                    && !restoredCards.contains(where: { $0.card.id == applied.card.id }) {
                    restoredCards.append(
                        CommittedPageChanges.RestoredCard(
                            card: applied.card,
                            identifiers: applied.identifiers
                        )
                    )
                }
                onPageCommitted(
                    CommittedPageChanges(
                        deletedCardIdentifiers: deletedCardIdentifiers.subtracting(
                            previouslyDeletedCardIdentifiers
                        ).union(absorbedIdentifiers),
                        restoredCards: restoredCards.reversed()
                    )
                )
                checkpoint = page.meta.nextCheckpoint

                // A partial-but-successful batch response is anomalous. Resolve
                // at most this page and leave later pages for the next sync.
                if resolvedPage.usedIndividualResolution {
                    return .completed(deletedCardIdentifiers: deletedCardIdentifiers)
                }
                guard page.meta.hasMore else {
                    return .completed(deletedCardIdentifiers: deletedCardIdentifiers)
                }
            }
        } catch is StaleActivationError {
            return .discardedStaleResponse
        } catch APIClientError.rejected(status: 409, message: _) {
            do {
                try ensureActive(activation)
                return .checkpointReset(
                    deletedCardIdentifiers: try resetServerBackedCards(
                        activation: activation
                    )
                )
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
        let requestedCardIDs = requestedCardIDs(in: entries)
        let serverCards = try await fetchCards(
            with: requestedCardIDs,
            activation: activation
        )
        let cardsByID = cardsByIdentifier(serverCards)
        var resolvedEntries: [ResolvedEntry] = []
        var usedIndividualResolution = false
        for entry in entries {
            let resolution = try await resolveEntry(
                entry,
                cardsByID: cardsByID,
                activation: activation
            )
            resolvedEntries.append(resolution.entry)
            usedIndividualResolution = usedIndividualResolution
                || resolution.usedIndividualResolution
        }
        return ResolvedPage(
            entries: resolvedEntries,
            usedIndividualResolution: usedIndividualResolution
        )
    }

    private func requestedCardIDs(in entries: [SyncFeedPage.Entry]) -> [String] {
        var requestedCardIDs: [String] = []
        var seenCardIDs: Set<String> = []
        for entry in entries where entry.operation != "delete" {
            let normalizedID = entry.resourceId.lowercased()
            if seenCardIDs.insert(normalizedID).inserted {
                requestedCardIDs.append(entry.resourceId)
            }
        }
        return requestedCardIDs
    }

    private func fetchCards(
        with requestedCardIDs: [String],
        activation: Activation
    ) async throws -> [StudyCard] {
        if requestedCardIDs.isEmpty {
            return []
        }
        let response: StudyCardBatchResponse = try await api.request(
            "/api/study/cards/batch",
            method: "POST",
            body: StudyCardBatchRequest(ids: requestedCardIDs)
        )
        try ensureActive(activation)
        return response.cards
    }

    private func cardsByIdentifier(_ serverCards: [StudyCard]) -> [String: StudyCard] {
        var cardsByID: [String: StudyCard] = [:]
        for card in serverCards {
            for identifier in cardIdentifiers(for: card) where cardsByID[identifier] == nil {
                cardsByID[identifier] = card
            }
        }
        return cardsByID
    }

    private func resolveEntry(
        _ entry: SyncFeedPage.Entry,
        cardsByID: [String: StudyCard],
        activation: Activation
    ) async throws -> (entry: ResolvedEntry, usedIndividualResolution: Bool) {
        try ensureActive(activation)
        if entry.operation == "delete" {
            return (.delete(resourceID: entry.resourceId), false)
        }

        let normalizedID = entry.resourceId.lowercased()
        if let card = cardsByID[normalizedID] {
            return (.upsert(card), false)
        }

        do {
            let card: StudyCard = try await api.request(
                "/api/study/cards/\(entry.resourceId)"
            )
            try ensureActive(activation)
            return (.upsert(card), true)
        } catch APIClientError.rejected(status: 404, message: _) {
            try ensureActive(activation)
            return (.delete(resourceID: entry.resourceId), true)
        }
    }

    private func commit(
        _ entries: [ResolvedEntry],
        checkpoint: Int64,
        activation: Activation,
        deletedCardIdentifiers initialDeletedCardIdentifiers: Set<String>,
        recordIndex: inout RecordIndex?
    ) throws -> CommitResult {
        var deletedCardIdentifiers = initialDeletedCardIdentifiers
        var appliedUpserts: [AppliedUpsert] = []
        var updatedRecordIndex = recordIndex ?? RecordIndex()
        try performTransaction {
            try ensureActive(activation)
            // No await occurs during a commit. These snapshots therefore see every
            // local write before this page, while avoiding one full query per card.
            var commitState = try makeCommitState(
                userID: activation.userID,
                hasEntries: !entries.isEmpty
            )
            for (index, entry) in entries.enumerated() {
                try beforeApplyingEntry(index)
                try ensureActive(activation)
                switch entry {
                case let .upsert(card):
                    if let applied = try upsert(
                        card,
                        userID: activation.userID,
                        recordIndex: &updatedRecordIndex,
                        commitState: &commitState
                    ) {
                        appliedUpserts.append(applied)
                        deletedCardIdentifiers.subtract(applied.identifiers)
                    }
                case let .delete(resourceID):
                    let (connectedRecords, _) = try connectedRecords(
                        startingWith: [resourceID.lowercased()],
                        userID: activation.userID,
                        in: &updatedRecordIndex
                    )
                    let removed = try removeServerCards(
                        connectedRecords,
                        commitState: &commitState
                    )
                    for removal in removed {
                        deletedCardIdentifiers.formUnion(removal.identifiers)
                        remove(
                            removal.record,
                            identifiers: removal.identifiers,
                            from: &updatedRecordIndex.recordsByIdentifier
                        )
                    }
                }
            }
            let state = try syncState(userID: activation.userID, savingIfCreated: false)
            state.cardCheckpoint = checkpoint
            state.updatedAt = .now
        }
        if !entries.isEmpty {
            recordIndex = updatedRecordIndex
        }
        return CommitResult(
            deletedCardIdentifiers: deletedCardIdentifiers,
            appliedUpserts: appliedUpserts
        )
    }

    private func upsert(
        _ serverCard: StudyCard,
        userID: Int,
        recordIndex: inout RecordIndex,
        commitState: inout CommitState
    ) throws -> AppliedUpsert? {
        guard let prepared = try prepareUpsert(
            serverCard,
            userID: userID,
            recordIndex: &recordIndex,
            commitState: commitState
        ) else { return nil }
        let applied: AppliedUpsert
        if let record = prepared.existingRecord {
            applied = try updateExistingRecord(
                record,
                using: prepared,
                recordIndex: &recordIndex,
                commitState: &commitState
            )
        } else {
            applied = try insertRecord(prepared, userID: userID, commitState: &commitState)
        }
        recordIndex.indexedRecordIDs.insert(applied.record.persistentModelID)
        addToIndex(applied.record, identifiers: applied.identifiers, in: &recordIndex.recordsByIdentifier)
        return applied
    }

    private func prepareUpsert(
        _ serverCard: StudyCard,
        userID: Int,
        recordIndex: inout RecordIndex,
        commitState: CommitState
    ) throws -> PreparedUpsert? {
        let (matchingRecords, identifiers) = try connectedRecords(
            startingWith: Set(cardIdentifiers(for: serverCard)),
            userID: userID,
            in: &recordIndex
        )
        let pending = commitState.pending(matching: identifiers)
        // Pending deletes, including quarantined ones, must never be recreated.
        guard !pending.contains(where: { $0.kind == "cardDelete" }) else { return nil }
        let record = preferredRecord(from: matchingRecords, for: serverCard, pending: pending)
        let localCard = try record.map {
            try StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
        let pendingReviews = pending.filter { $0.kind == "review" && $0.lastError == nil }
        let preservesLocalContent = preservesLocalContent(matchingRecords, pending: pending)
        let merged = mergedCard(
            serverCard,
            localCard: localCard,
            pendingReviewCard: latestPendingReviewCard(pendingReviews, matchingRecords: matchingRecords),
            preservingPendingReview: !pendingReviews.isEmpty || pending.contains {
                $0.kind == "cardAction" && $0.lastError == nil
            },
            preservingLocalContent: preservesLocalContent
        )
        return PreparedUpsert(
            serverCard: serverCard,
            card: merged,
            existingRecord: record,
            matchingRecords: matchingRecords,
            pending: pending,
            identifiers: identifiers,
            preservesLocalContent: preservesLocalContent
        )
    }

    private func preservesLocalContent(
        _ records: [LocalCardRecord],
        pending: [PendingMutation]
    ) -> Bool {
        records.contains { $0.locallyUpdatedAt != nil } || pending.contains {
            ($0.kind == "cardCreate" || $0.kind == "cardUpdate") && $0.lastError == nil
        }
    }

    private func latestPendingReviewCard(
        _ pendingReviews: [PendingMutation],
        matchingRecords: [LocalCardRecord]
    ) -> StudyCard? {
        pendingReviews.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.lowercased() < $1.id.lowercased()
        }.lazy.compactMap { mutation in
            matchingRecords.first { $0.id.lowercased() == mutation.resourceID.lowercased() }
        }.first.flatMap {
            try? StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
    }

    private func updateExistingRecord(
        _ record: LocalCardRecord,
        using prepared: PreparedUpsert,
        recordIndex: inout RecordIndex,
        commitState: inout CommitState
    ) throws -> AppliedUpsert {
        let previousIdentifiers = try identifiers(for: record)
        let duplicates = try removableDuplicates(for: record, prepared: prepared)
        let mediaPreparedAt = preparedMediaTimestamp(for: prepared.card, from: [record] + duplicates)
        let merged = record.id == prepared.card.id
            ? prepared.card
            : prepared.card.replacingIdentity(id: record.id, syncId: prepared.serverCard.reviewCardID)
        record.replacePayload(encoded: try StorageCodec.encoder.encode(merged))
        record.serverUpdatedAt = prepared.serverCard.updatedAt
        updateDirtyTimestamp(of: record, preservingLocalContent: prepared.preservesLocalContent)
        let previousActiveCount = prepared.matchingRecords.filter(\.isInActiveSession).count
        reconcileActiveSessionMetadata(from: prepared.matchingRecords, into: record)
        commitState.activeCardCount += (record.isInActiveSession ? 1 : 0) - previousActiveCount
        record.mediaPreparedAt = mediaPreparedAt
        let absorbedIdentifiers = try removeDuplicates(duplicates, recordIndex: &recordIndex)
        remove(record, identifiers: previousIdentifiers, from: &recordIndex.recordsByIdentifier)
        return AppliedUpsert(
            record: record,
            card: merged,
            identifiers: prepared.identifiers,
            absorbedIdentifiers: absorbedIdentifiers
        )
    }

    private func removableDuplicates(
        for record: LocalCardRecord,
        prepared: PreparedUpsert
    ) throws -> [LocalCardRecord] {
        let pendingResourceIDs = Set(prepared.pending.map { $0.resourceID.lowercased() })
        return try prepared.matchingRecords.filter { duplicate in
            guard duplicate !== record, duplicate.locallyUpdatedAt == nil else { return false }
            return pendingResourceIDs.isDisjoint(with: try identifiers(for: duplicate))
        }
    }

    private func updateDirtyTimestamp(of record: LocalCardRecord, preservingLocalContent: Bool) {
        if preservingLocalContent {
            record.locallyUpdatedAt = record.locallyUpdatedAt ?? .now
        } else {
            record.locallyUpdatedAt = nil
        }
    }

    private func removeDuplicates(
        _ duplicates: [LocalCardRecord],
        recordIndex: inout RecordIndex
    ) throws -> Set<String> {
        var absorbedIdentifiers: Set<String> = []
        for duplicate in duplicates {
            let identifiers = try identifiers(for: duplicate)
            absorbedIdentifiers.formUnion(identifiers)
            remove(duplicate, identifiers: identifiers, from: &recordIndex.recordsByIdentifier)
            context.delete(duplicate)
        }
        return absorbedIdentifiers
    }

    private func insertRecord(
        _ prepared: PreparedUpsert,
        userID: Int,
        commitState: inout CommitState
    ) throws -> AppliedUpsert {
        let record = LocalCardRecord(
            card: prepared.card,
            userID: userID,
            queueIndex: commitState.activeCardCount,
            payload: try StorageCodec.encoder.encode(prepared.card)
        )
        record.serverUpdatedAt = prepared.serverCard.updatedAt
        record.locallyUpdatedAt = prepared.preservesLocalContent ? .now : nil
        context.insert(record)
        commitState.activeCardCount += 1
        return AppliedUpsert(
            record: record,
            card: prepared.card,
            identifiers: prepared.identifiers,
            absorbedIdentifiers: []
        )
    }

    private func connectedRecords(
        startingWith initialIdentifiers: Set<String>,
        userID: Int,
        in recordIndex: inout RecordIndex
    ) throws -> ([LocalCardRecord], Set<String>) {
        var identifiers = initialIdentifiers
        var pendingIdentifiers = Array(initialIdentifiers)
        var nextIdentifierIndex = 0
        var seen: Set<ObjectIdentifier> = []
        var records: [LocalCardRecord] = []

        while nextIdentifierIndex < pendingIdentifiers.count {
            let identifier = pendingIdentifiers[nextIdentifierIndex]
            nextIdentifierIndex += 1
            try loadRecords(
                matching: identifier,
                userID: userID,
                into: &recordIndex
            )
            for record in recordIndex.recordsByIdentifier[identifier] ?? []
            where seen.insert(ObjectIdentifier(record)).inserted {
                records.append(record)
                for discoveredIdentifier in try self.identifiers(for: record)
                where identifiers.insert(discoveredIdentifier).inserted {
                    pendingIdentifiers.append(discoveredIdentifier)
                }
            }
        }
        return (records, identifiers)
    }

    private func loadRecords(
        matching identifier: String,
        userID: Int,
        into recordIndex: inout RecordIndex
    ) throws {
        guard recordIndex.loadedIdentifiers.insert(identifier).inserted else { return }
        let records = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.normalizedID == identifier || $0.syncID == identifier)
                }
            )
        )
        for record in records {
            guard recordIndex.indexedRecordIDs.insert(record.persistentModelID).inserted else {
                continue
            }
            onIndexingRecord()
            addToIndex(
                record,
                identifiers: try identifiers(for: record),
                in: &recordIndex.recordsByIdentifier
            )
        }
    }

    private func preferredRecord(
        from records: [LocalCardRecord],
        for serverCard: StudyCard,
        pending: [PendingMutation]
    ) -> LocalCardRecord? {
        let pendingResourceIDs = Set(pending.lazy.filter {
            $0.kind == "cardCreate" || $0.kind == "cardUpdate"
                || $0.kind == "cardAction" || $0.kind == "review"
        }.map { $0.resourceID.lowercased() })
        return records.max { lhs, rhs in
            let lhsPriority = recordPriority(
                lhs,
                for: serverCard,
                pendingResourceIDs: pendingResourceIDs
            )
            let rhsPriority = recordPriority(
                rhs,
                for: serverCard,
                pendingResourceIDs: pendingResourceIDs
            )
            if lhsPriority == rhsPriority {
                return lhs.id.lowercased() < rhs.id.lowercased()
            }
            return lhsPriority < rhsPriority
        }
    }

    private func recordPriority(
        _ record: LocalCardRecord,
        for serverCard: StudyCard,
        pendingResourceIDs: Set<String>
    ) -> (Int, Int, Date, Int, Int, Date) {
        (
            record.locallyUpdatedAt == nil ? 0 : 1,
            pendingResourceIDs.contains(record.id.lowercased()) ? 1 : 0,
            record.locallyUpdatedAt ?? .distantPast,
            record.id.lowercased() == serverCard.id.lowercased() ? 1 : 0,
            record.isInActiveSession ? 1 : 0,
            record.serverUpdatedAt
        )
    }

    private func reconcileActiveSessionMetadata(
        from records: [LocalCardRecord],
        into survivor: LocalCardRecord
    ) {
        let activeRecords = records.filter(\.isInActiveSession)
        survivor.isInActiveSession = !activeRecords.isEmpty
        if let firstQueueIndex = activeRecords.map(\.queueIndex).min() {
            survivor.queueIndex = firstQueueIndex
        }
        for record in activeRecords where record !== survivor {
            record.isInActiveSession = false
        }
    }

    private func preparedMediaTimestamp(
        for card: StudyCard,
        from records: [LocalCardRecord]
    ) -> Date? {
        records.compactMap { record in
            guard let preparedAt = record.mediaPreparedAt,
                  let storedCard = try? StorageCodec.decoder.decode(
                      StudyCard.self,
                      from: record.payload
                  ),
                  storedCard.mediaURLs == card.mediaURLs
            else { return nil }
            return preparedAt
        }.max()
    }

    private func mergedCard(
        _ serverCard: StudyCard,
        localCard: StudyCard?,
        pendingReviewCard: StudyCard?,
        preservingPendingReview: Bool,
        preservingLocalContent: Bool
    ) -> StudyCard {
        guard let localCard else {
            return serverCard
        }
        let serverCard = serverCard.resolvingProgressionMetadata(
            fallingBackTo: localCard
        )
        guard preservingPendingReview || preservingLocalContent else {
            return serverCard
        }
        let retainedPresentation = if preservingLocalContent {
            localCard.cardType == serverCard.cardType
                ? localCard.serverPresentation
                : nil
        } else {
            serverCard.serverPresentation
        }
        return StudyCard(
            id: serverCard.id,
            syncId: serverCard.syncId ?? localCard.syncId,
            noteId: serverCard.noteId,
            revision: preservingLocalContent ? localCard.revision : serverCard.revision,
            cardType: serverCard.cardType,
            prompt: preservingLocalContent ? localCard.prompt : serverCard.prompt,
            answer: preservingLocalContent ? localCard.answer : serverCard.answer,
            // A presentation is derived for a specific card type and content
            // snapshot. A racing server type change must not relabel the dirty
            // local projection with the new type.
            serverPresentation: retainedPresentation,
            state: preservingPendingReview
                ? (pendingReviewCard ?? localCard).state
                : serverCard.state,
            answerAudioSource: serverCard.answerAudioSource,
            // Review state and mastery form one scheduling snapshot. Otherwise
            // the feed's computed mastery is authoritative; a missing value is
            // retained only for compatibility with lean or legacy responses.
            masteryLevel: preservingPendingReview
                ? (pendingReviewCard ?? localCard).masteryLevel
                : serverCard.masteryLevel ?? localCard.masteryLevel,
            variantGroupId: serverCard.variantGroupId,
            variantStatus: serverCard.variantStatus,
            introductionCohortId: serverCard.introductionCohortId,
            selectionPolicy: serverCard.selectionPolicy,
            priorityUntil: serverCard.priorityUntil,
            introductionAvailableAt: serverCard.introductionAvailableAt,
            createdAt: serverCard.createdAt,
            updatedAt: preservingPendingReview || preservingLocalContent
                ? localCard.updatedAt
                : serverCard.updatedAt
        )
    }

    private func removeServerCards(
        _ records: [LocalCardRecord],
        commitState: inout CommitState
    ) throws -> [RemovedRecord] {
        var removed: [RemovedRecord] = []
        for record in records {
            let identifiers = try identifiers(for: record)
            guard record.locallyUpdatedAt == nil,
                  commitState.pending(matching: identifiers).isEmpty
            else {
                continue
            }
            if record.isInActiveSession { commitState.activeCardCount -= 1 }
            context.delete(record)
            removed.append(RemovedRecord(record: record, identifiers: identifiers))
        }
        return removed
    }

    private func addToIndex(
        _ record: LocalCardRecord,
        identifiers: Set<String>,
        in recordsByIdentifier: inout [String: [LocalCardRecord]]
    ) {
        for identifier in identifiers {
            recordsByIdentifier[identifier, default: []].removeAll { $0 === record }
            recordsByIdentifier[identifier, default: []].append(record)
        }
    }

    private func remove(
        _ record: LocalCardRecord,
        identifiers: Set<String>,
        from recordsByIdentifier: inout [String: [LocalCardRecord]]
    ) {
        for identifier in identifiers {
            recordsByIdentifier[identifier]?.removeAll { $0 === record }
            if recordsByIdentifier[identifier]?.isEmpty == true {
                recordsByIdentifier.removeValue(forKey: identifier)
            }
        }
    }

    private func resetServerBackedCards(activation: Activation) throws -> Set<String> {
        let userID = activation.userID
        var deletedCardIdentifiers: Set<String> = []
        try performTransaction {
            try ensureActive(activation)
            let records = try context.fetch(
                FetchDescriptor<LocalCardRecord>(
                    predicate: #Predicate { $0.userID == userID }
                )
            )
            let pendingByIdentifier = try pendingMutationIndex(userID: userID)
            for record in records where record.locallyUpdatedAt == nil {
                let identifiers = try identifiers(for: record)
                if identifiers.allSatisfy({ pendingByIdentifier[$0] == nil }) {
                    context.delete(record)
                    deletedCardIdentifiers.formUnion(identifiers)
                }
            }
            let state = try syncState(userID: userID, savingIfCreated: false)
            state.cardCheckpoint = 0
            state.updatedAt = .now
        }
        return deletedCardIdentifiers
    }

    private func identifiers(for record: LocalCardRecord) throws -> Set<String> {
        Set([record.normalizedID, record.syncID])
    }

    private func cardIdentifiers(for card: StudyCard) -> [String] {
        [card.id, card.reviewCardID].map { $0.lowercased() }
    }

    private func makeCommitState(userID: Int, hasEntries: Bool) throws -> CommitState {
        guard hasEntries else { return CommitState(pendingByIdentifier: [:], activeCardCount: 0) }
        let pending = try pendingMutationIndex(userID: userID)
        onCommitQuery(.activeCardCount)
        let activeCount = try context.fetchCount(FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.isInActiveSession }
        ))
        return CommitState(pendingByIdentifier: pending, activeCardCount: activeCount)
    }

    private func pendingMutationIndex(userID: Int) throws -> [String: [PendingMutation]] {
        onCommitQuery(.pendingMutations)
        let pending = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate"
                            || $0.kind == "cardUpdate"
                            || $0.kind == "cardDelete"
                            || $0.kind == "cardAction"
                            || $0.kind == "review")
                }
            )
        )
        return Dictionary(grouping: pending) { $0.resourceID.lowercased() }
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
        try Task.checkCancellation()
        try ensureCurrentActivation(activation)
    }

    private func ensureCurrentActivation(_ activation: Activation) throws {
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

    private func clearCachedRecords() {
        cachedRecordsUserID = nil
        cachedRecordIndex = nil
        cachedAtSaveRevision = nil
    }
}

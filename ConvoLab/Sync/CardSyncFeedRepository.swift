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
            var foundIdentifierCollection = false
            for key in [
                ModelContext.NotificationKey.insertedIdentifiers,
                .updatedIdentifiers,
                .deletedIdentifiers,
                .invalidatedAllIdentifiers,
            ] {
                let value = userInfo[key.rawValue]
                if let identifiers = value as? [PersistentIdentifier] {
                    foundIdentifierCollection = true
                    if identifiers.contains(where: {
                        relevantEntityNames.contains($0.entityName)
                    }) {
                        return true
                    }
                } else if let identifiers = value as? Set<PersistentIdentifier> {
                    foundIdentifierCollection = true
                    if identifiers.contains(where: {
                        relevantEntityNames.contains($0.entityName)
                    }) {
                        return true
                    }
                } else if let invalidatedAll = value as? Bool, invalidatedAll {
                    return true
                }
            }
            // Unknown notification payloads must invalidate conservatively.
            return !foundIdentifierCollection
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private let api: APIClient
    private let context: ModelContext
    private let beforeApplyingEntry: (Int) throws -> Void
    private let onIndexingRecord: () -> Void
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
        onIndexingRecord: @escaping () -> Void = {}
    ) {
        self.api = api
        self.context = context
        self.beforeApplyingEntry = beforeApplyingEntry
        self.onIndexingRecord = onIndexingRecord
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
                try ensureActive(activation)
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
        activation: Activation,
        deletedCardIdentifiers initialDeletedCardIdentifiers: Set<String>,
        recordIndex: inout RecordIndex?
    ) throws -> CommitResult {
        var deletedCardIdentifiers = initialDeletedCardIdentifiers
        var appliedUpserts: [AppliedUpsert] = []
        var updatedRecordIndex = recordIndex ?? RecordIndex()
        try performTransaction {
            try ensureActive(activation)
            for (index, entry) in entries.enumerated() {
                try beforeApplyingEntry(index)
                try ensureActive(activation)
                switch entry {
                case let .upsert(card):
                    if let applied = try upsert(
                        card,
                        userID: activation.userID,
                        recordIndex: &updatedRecordIndex
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
                        userID: activation.userID
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
        recordIndex: inout RecordIndex
    ) throws -> AppliedUpsert? {
        let (matchingRecords, identifiers) = try connectedRecords(
            startingWith: Set(cardIdentifiers(for: serverCard)),
            userID: userID,
            in: &recordIndex
        )
        let pending = try pendingMutations(userID: userID, matching: identifiers)
        // Local content mutations, including rejected mutations held for user
        // inspection, remain authoritative until explicitly resolved. The feed
        // must not silently overwrite or recreate that unsynced local intent.
        guard !pending.contains(where: { $0.kind == "cardDelete" }) else { return nil }
        let record = preferredRecord(
            from: matchingRecords,
            for: serverCard,
            pending: pending
        )
        let localCard = try record.flatMap {
            try StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }
        let pendingReviews = pending.filter {
            $0.kind == "review" && $0.lastError == nil
        }
        let hasPendingReview = !pendingReviews.isEmpty || pending.contains {
            $0.kind == "cardAction" && $0.lastError == nil
        }
        let pendingReviewCard = pendingReviews
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.lowercased() < $1.id.lowercased()
            }
            .lazy
            .compactMap { mutation in
                matchingRecords.first {
                    $0.id.lowercased() == mutation.resourceID.lowercased()
                }
            }
            .first
            .flatMap {
                try? StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
            }
        let preservesLocalContent = matchingRecords.contains {
            $0.locallyUpdatedAt != nil
        } || pending.contains {
            $0.kind == "cardCreate" || $0.kind == "cardUpdate"
        }
        var merged = mergedCard(
            serverCard,
            localCard: localCard,
            pendingReviewCard: pendingReviewCard,
            preservingPendingReview: hasPendingReview,
            preservingLocalContent: preservesLocalContent
        )

        let appliedRecord: LocalCardRecord
        var absorbedIdentifiers: Set<String> = []
        if let record {
            let recordIdentifiers = try self.identifiers(for: record)
            let pendingResourceIDs = Set(pending.map { $0.resourceID.lowercased() })
            var removableDuplicates: [LocalCardRecord] = []
            for duplicate in matchingRecords
            where duplicate !== record && duplicate.locallyUpdatedAt == nil {
                let duplicateIdentifiers = try self.identifiers(for: duplicate)
                if pendingResourceIDs.isDisjoint(with: duplicateIdentifiers) {
                    removableDuplicates.append(duplicate)
                }
            }
            let replicaRecords = [record] + removableDuplicates
            let mediaPreparedAt = preparedMediaTimestamp(
                for: merged,
                from: replicaRecords
            )
            if record.id != merged.id {
                merged = merged.replacingIdentity(
                    id: record.id,
                    syncId: serverCard.reviewCardID
                )
            }
            record.replacePayload(encoded: try StorageCodec.encoder.encode(merged))
            record.serverUpdatedAt = serverCard.updatedAt
            if preservesLocalContent, record.locallyUpdatedAt == nil {
                record.locallyUpdatedAt = .now
            } else if !preservesLocalContent {
                record.locallyUpdatedAt = nil
            }
            reconcileActiveSessionMetadata(
                from: matchingRecords,
                into: record
            )
            record.mediaPreparedAt = mediaPreparedAt
            for duplicate in removableDuplicates {
                let duplicateIdentifiers = try self.identifiers(for: duplicate)
                absorbedIdentifiers.formUnion(duplicateIdentifiers)
                remove(
                    duplicate,
                    identifiers: duplicateIdentifiers,
                    from: &recordIndex.recordsByIdentifier
                )
                context.delete(duplicate)
            }
            remove(
                record,
                identifiers: recordIdentifiers,
                from: &recordIndex.recordsByIdentifier
            )
            appliedRecord = record
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
                payload: try StorageCodec.encoder.encode(merged)
            )
            record.serverUpdatedAt = serverCard.updatedAt
            record.locallyUpdatedAt = preservesLocalContent ? .now : nil
            context.insert(record)
            appliedRecord = record
        }
        recordIndex.indexedRecordIDs.insert(appliedRecord.persistentModelID)
        addToIndex(
            appliedRecord,
            identifiers: identifiers,
            in: &recordIndex.recordsByIdentifier
        )
        return AppliedUpsert(
            record: appliedRecord,
            card: merged,
            identifiers: identifiers,
            absorbedIdentifiers: absorbedIdentifiers
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
            createdAt: serverCard.createdAt,
            updatedAt: preservingPendingReview || preservingLocalContent
                ? localCard.updatedAt
                : serverCard.updatedAt
        )
    }

    private func removeServerCards(
        _ records: [LocalCardRecord],
        userID: Int
    ) throws -> [RemovedRecord] {
        var removed: [RemovedRecord] = []
        for record in records {
            let identifiers = try identifiers(for: record)
            guard record.locallyUpdatedAt == nil,
                  try pendingMutations(userID: userID, matching: identifiers).isEmpty
            else {
                continue
            }
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
            for record in records where record.locallyUpdatedAt == nil {
                let identifiers = try identifiers(for: record)
                if try pendingMutations(
                    userID: userID,
                    matching: identifiers
                ).isEmpty {
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
                            || $0.kind == "cardAction"
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

    private func clearCachedRecords() {
        cachedRecordsUserID = nil
        cachedRecordIndex = nil
        cachedAtSaveRevision = nil
    }
}

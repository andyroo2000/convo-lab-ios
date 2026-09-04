import Foundation
import SwiftData

@MainActor
struct StudyCardLocalRepository {
    private enum MergeMode {
        case activeSession
        case offlineReserve(preservingActiveSessionOrder: Bool)

        func prepare(_ records: [LocalCardRecord]) {
            guard case .activeSession = self else { return }
            records.forEach { $0.isInActiveSession = false }
        }

        func applyQueueMetadata(to record: LocalCardRecord, index: Int) {
            switch self {
            case .activeSession:
                record.isInActiveSession = true
                record.queueIndex = index
            case let .offlineReserve(preservingActiveSessionOrder):
                if !preservingActiveSessionOrder || !record.isInActiveSession {
                    record.queueIndex = index
                }
            }
        }

        var newRecordIsActive: Bool {
            if case .activeSession = self { return true }
            return false
        }
    }

    private struct MatchIdentity {
        let id: String
        let syncID: String
        let normalizedID: String
        let normalizedSyncID: String

        init(card: StudyCard) {
            id = card.id
            syncID = card.reviewCardID
            normalizedID = card.id.lowercased()
            normalizedSyncID = card.reviewCardID.lowercased()
        }
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func replaceActiveSession(with cards: [StudyCard], userID: Int) throws {
        try merge(cards, userID: userID, mode: .activeSession)
    }

    func mergeOfflineReserve(
        _ cards: [StudyCard],
        userID: Int,
        preservingActiveSessionOrder: Bool = false
    ) throws {
        try merge(
            cards,
            userID: userID,
            mode: .offlineReserve(preservingActiveSessionOrder: preservingActiveSessionOrder)
        )
    }

    private func merge(
        _ cards: [StudyCard],
        userID: Int,
        mode: MergeMode
    ) throws {
        let existing = try records(userID: userID)
        mode.prepare(existing)
        var byIdentifier = recordsByIdentifier(existing)

        for (index, card) in cards.enumerated() {
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if let record = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
                try merge(card, into: record, at: index, mode: mode)
            } else {
                let record = LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
                record.isInActiveSession = mode.newRecordIsActive
                context.insert(record)
                indexRecord(record, by: identifiers, in: &byIdentifier)
            }
        }
        try context.save()
    }

    private func merge(
        _ card: StudyCard,
        into record: LocalCardRecord,
        at index: Int,
        mode: MergeMode
    ) throws {
        // Queue membership and position are server/session metadata, so keep
        // them current even while local card content remains dirty.
        mode.applyQueueMetadata(to: record, index: index)
        guard record.locallyUpdatedAt == nil else { return }
        let resolvedCard = resolvedProgressionMetadata(for: card, storedIn: record)
        let rebasedCard = record.id == resolvedCard.id
            ? resolvedCard
            : resolvedCard.replacingIdentity(
                id: record.id,
                syncId: resolvedCard.reviewCardID
            )
        record.replacePayload(encoded: try StorageCodec.encoder.encode(rebasedCard))
        record.serverUpdatedAt = card.updatedAt
    }

    private func indexRecord(
        _ record: LocalCardRecord,
        by identifiers: Set<String>,
        in records: inout [String: LocalCardRecord]
    ) {
        for identifier in identifiers {
            records[identifier] = record
        }
    }

    func markProgressionLocked(_ card: StudyCard, userID: Int) throws {
        try markProgressionLocked(
            matching: StudyCardIdentity.identifiers(for: card),
            userID: userID
        )
    }

    func markProgressionLocked(
        matching identifiers: Set<String>,
        userID: Int
    ) throws {
        let normalizedIdentifiers = StudyCardIdentity.normalized(identifiers)
        var changed = false
        for record in try records(userID: userID)
        where !normalizedIdentifiers.isDisjoint(with: [record.normalizedID, record.syncID]) {
            guard let currentCard = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            ) else { continue }
            record.replacePayload(encoded: try StorageCodec.encoder.encode(
                currentCard.replacingVariantStatus("locked")
            ))
            record.isInActiveSession = false
            changed = true
        }
        if changed {
            try context.save()
        }
    }

    private func resolvedProgressionMetadata(
        for card: StudyCard,
        storedIn record: LocalCardRecord
    ) -> StudyCard {
        guard !card.includesProgressionMetadataProjection else { return card }
        guard let storedCard = try? StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        ) else { return card }
        return card.resolvingProgressionMetadata(fallingBackTo: storedCard)
    }

    func updateMediaPreparedState(
        for cards: [StudyCard],
        userID: Int,
        cachedKeys: Set<String>,
        clearingOtherRecords: Bool = false
    ) throws {
        let cardsByIdentifier = cardsByIdentifier(cards)
        for record in try records(userID: userID) {
            updateMediaPreparedState(
                of: record,
                using: cardsByIdentifier,
                cachedKeys: cachedKeys,
                clearingIfMissing: clearingOtherRecords
            )
        }
        try context.save()
    }

    private func cardsByIdentifier(_ cards: [StudyCard]) -> [String: StudyCard] {
        var cardsByIdentifier: [String: StudyCard] = [:]
        for card in cards {
            for identifier in StudyCardIdentity.identifiers(for: card)
            where cardsByIdentifier[identifier] == nil {
                cardsByIdentifier[identifier] = card
            }
        }
        return cardsByIdentifier
    }

    private func updateMediaPreparedState(
        of record: LocalCardRecord,
        using cardsByIdentifier: [String: StudyCard],
        cachedKeys: Set<String>,
        clearingIfMissing: Bool
    ) {
        guard let card = recordIdentifiers(record).lazy.compactMap({
            cardsByIdentifier[$0]
        }).first else {
            if clearingIfMissing {
                record.mediaPreparedAt = nil
            }
            return
        }
        let isPrepared = card.mediaURLs.allSatisfy {
            cachedKeys.contains(MediaCache.stableCacheKey(for: $0))
        }
        record.mediaPreparedAt = isPrepared ? .now : nil
    }

    func activeCards(userID: Int) throws -> [StudyCard] {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID && $0.isInActiveSession },
            sortBy: [SortDescriptor(\.queueIndex)]
        )
        return try context.fetch(descriptor).compactMap(decodeCard)
    }

    func libraryCards(userID: Int) throws -> [StudyCard] {
        let descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.serverUpdatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(decodeCard)
    }

    func record(matching card: StudyCard, userID: Int) throws -> LocalCardRecord? {
        let identity = MatchIdentity(card: card)
        var matches = try records(userID: userID, normalizedID: identity.normalizedID)
        matches += try records(userID: userID, syncID: identity.normalizedID)
        if identity.normalizedSyncID != identity.normalizedID {
            matches += try records(userID: userID, normalizedID: identity.normalizedSyncID)
            matches += try records(userID: userID, syncID: identity.normalizedSyncID)
        }
        return matches.min { lhs, rhs in
            isPreferredMatch(lhs, over: rhs, identity: identity)
        }
    }

    private func records(userID: Int, normalizedID: String) throws -> [LocalCardRecord] {
        try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate {
                    $0.userID == userID && $0.normalizedID == normalizedID
                }
            )
        )
    }

    private func records(userID: Int, syncID: String) throws -> [LocalCardRecord] {
        try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID && $0.syncID == syncID }
            )
        )
    }

    private func records(userID: Int) throws -> [LocalCardRecord] {
        try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
    }

    private func decodeCard(record: LocalCardRecord) -> StudyCard? {
        try? StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    private func matchPriority(
        _ record: LocalCardRecord,
        identity: MatchIdentity
    ) -> Int {
        if record.id == identity.id { return 0 }
        if record.normalizedID == identity.normalizedID { return 1 }
        if record.id == identity.syncID { return 2 }
        if record.normalizedID == identity.normalizedSyncID { return 3 }
        if record.syncID == identity.normalizedID { return 4 }
        if record.syncID == identity.normalizedSyncID { return 5 }
        return 6
    }

    private func isPreferredMatch(
        _ lhs: LocalCardRecord,
        over rhs: LocalCardRecord,
        identity: MatchIdentity
    ) -> Bool {
        let lhsPriority = matchPriority(lhs, identity: identity)
        let rhsPriority = matchPriority(rhs, identity: identity)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

        let lhsIsDirty = lhs.locallyUpdatedAt != nil
        let rhsIsDirty = rhs.locallyUpdatedAt != nil
        if lhsIsDirty != rhsIsDirty { return lhsIsDirty }
        if lhs.locallyUpdatedAt != rhs.locallyUpdatedAt {
            return (lhs.locallyUpdatedAt ?? .distantPast) > (rhs.locallyUpdatedAt ?? .distantPast)
        }
        if lhs.serverUpdatedAt != rhs.serverUpdatedAt {
            return lhs.serverUpdatedAt > rhs.serverUpdatedAt
        }
        if lhs.normalizedID != rhs.normalizedID { return lhs.normalizedID < rhs.normalizedID }
        return lhs.id < rhs.id
    }

    private func recordIdentifiers(_ record: LocalCardRecord) -> Set<String> {
        Set([record.normalizedID, record.syncID]).filter { !$0.isEmpty }
    }

    private func recordsByIdentifier(
        _ records: [LocalCardRecord]
    ) -> [String: LocalCardRecord] {
        var result: [String: LocalCardRecord] = [:]
        for record in records {
            for identifier in recordIdentifiers(record) where result[identifier] == nil {
                result[identifier] = record
            }
        }
        return result
    }
}

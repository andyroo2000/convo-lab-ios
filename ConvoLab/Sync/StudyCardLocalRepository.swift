import Foundation
import SwiftData

@MainActor
struct StudyCardLocalRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func replaceActiveSession(with cards: [StudyCard], userID: Int) throws {
        let existing = try records(userID: userID)
        existing.forEach { $0.isInActiveSession = false }
        var byIdentifier = recordsByIdentifier(existing)

        for (index, card) in cards.enumerated() {
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if let record = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
                record.isInActiveSession = true
                // Queue membership and position are server/session metadata, so
                // keep them current even while local card content remains dirty.
                record.queueIndex = index
                guard record.locallyUpdatedAt == nil else { continue }
                let storedCard = try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                )
                let resolvedCard = storedCard.map {
                    card.resolvingProgressionMetadata(fallingBackTo: $0)
                } ?? card
                let rebasedCard = record.id == resolvedCard.id
                    ? resolvedCard
                    : resolvedCard.replacingIdentity(
                        id: record.id,
                        syncId: resolvedCard.reviewCardID
                    )
                record.replacePayload(encoded: try StorageCodec.encoder.encode(rebasedCard))
                record.serverUpdatedAt = card.updatedAt
            } else {
                let record = LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
                context.insert(record)
                for identifier in identifiers {
                    byIdentifier[identifier] = record
                }
            }
        }
        try context.save()
    }

    func mergeOfflineReserve(
        _ cards: [StudyCard],
        userID: Int,
        preservingActiveSessionOrder: Bool = false
    ) throws {
        let existing = try records(userID: userID)
        var byIdentifier = recordsByIdentifier(existing)

        for (index, card) in cards.enumerated() {
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if let record = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
                if !preservingActiveSessionOrder || !record.isInActiveSession {
                    record.queueIndex = index
                }
                guard record.locallyUpdatedAt == nil else { continue }
                let storedCard = try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                )
                let resolvedCard = storedCard.map {
                    card.resolvingProgressionMetadata(fallingBackTo: $0)
                } ?? card
                let rebasedCard = record.id == resolvedCard.id
                    ? resolvedCard
                    : resolvedCard.replacingIdentity(
                        id: record.id,
                        syncId: resolvedCard.reviewCardID
                    )
                record.replacePayload(encoded: try StorageCodec.encoder.encode(rebasedCard))
                record.serverUpdatedAt = card.updatedAt
            } else {
                let record = LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
                record.isInActiveSession = false
                context.insert(record)
                for identifier in identifiers {
                    byIdentifier[identifier] = record
                }
            }
        }
        try context.save()
    }

    func markProgressionLocked(_ card: StudyCard, userID: Int) throws {
        guard let record = try record(matching: card, userID: userID) else { return }
        let restoredCard = record.id == card.id
            ? card
            : card.replacingIdentity(id: record.id, syncId: card.reviewCardID)
        record.replacePayload(encoded: try StorageCodec.encoder.encode(
            restoredCard.replacingVariantStatus("locked")
        ))
        record.isInActiveSession = false
        try context.save()
    }

    func updateMediaPreparedState(
        for cards: [StudyCard],
        userID: Int,
        cachedKeys: Set<String>,
        clearingOtherRecords: Bool = false
    ) throws {
        var cardsByIdentifier: [String: StudyCard] = [:]
        for card in cards {
            for identifier in StudyCardIdentity.identifiers(for: card)
            where cardsByIdentifier[identifier] == nil {
                cardsByIdentifier[identifier] = card
            }
        }
        for record in try records(userID: userID) {
            guard let card = recordIdentifiers(record).lazy.compactMap({
                cardsByIdentifier[$0]
            }).first else {
                if clearingOtherRecords {
                    record.mediaPreparedAt = nil
                }
                continue
            }
            let isPrepared = card.mediaURLs.allSatisfy {
                cachedKeys.contains(MediaCache.stableCacheKey(for: $0))
            }
            record.mediaPreparedAt = isPrepared ? .now : nil
        }
        try context.save()
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
        let normalizedID = card.id.lowercased()
        let normalizedSyncID = card.reviewCardID.lowercased()
        var matches = try records(userID: userID, normalizedID: normalizedID)
        matches += try records(userID: userID, syncID: normalizedID)
        if normalizedSyncID != normalizedID {
            matches += try records(userID: userID, normalizedID: normalizedSyncID)
            matches += try records(userID: userID, syncID: normalizedSyncID)
        }
        return matches.min { lhs, rhs in
            isPreferredMatch(
                lhs,
                over: rhs,
                id: card.id,
                syncID: card.reviewCardID,
                normalizedID: normalizedID,
                normalizedSyncID: normalizedSyncID
            )
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
        id: String,
        syncID: String,
        normalizedID: String,
        normalizedSyncID: String
    ) -> Int {
        if record.id == id { return 0 }
        if record.normalizedID == normalizedID { return 1 }
        if record.id == syncID { return 2 }
        if record.normalizedID == normalizedSyncID { return 3 }
        if record.syncID == normalizedID { return 4 }
        if record.syncID == normalizedSyncID { return 5 }
        return 6
    }

    private func isPreferredMatch(
        _ lhs: LocalCardRecord,
        over rhs: LocalCardRecord,
        id: String,
        syncID: String,
        normalizedID: String,
        normalizedSyncID: String
    ) -> Bool {
        let lhsPriority = matchPriority(
            lhs,
            id: id,
            syncID: syncID,
            normalizedID: normalizedID,
            normalizedSyncID: normalizedSyncID
        )
        let rhsPriority = matchPriority(
            rhs,
            id: id,
            syncID: syncID,
            normalizedID: normalizedID,
            normalizedSyncID: normalizedSyncID
        )
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

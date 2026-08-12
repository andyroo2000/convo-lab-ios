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
                let rebasedCard = record.id == card.id
                    ? card
                    : card.replacingIdentity(
                        id: record.id,
                        syncId: card.reviewCardID
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

    func mergeOfflineReserve(_ cards: [StudyCard], userID: Int) throws {
        let existing = try records(userID: userID)
        var byIdentifier = recordsByIdentifier(existing)

        for (index, card) in cards.enumerated() {
            let identifiers = StudyCardIdentity.identifiers(for: card)
            if let record = identifiers.lazy.compactMap({ byIdentifier[$0] }).first {
                record.queueIndex = index
                guard record.locallyUpdatedAt == nil else { continue }
                let rebasedCard = record.id == card.id
                    ? card
                    : card.replacingIdentity(
                        id: record.id,
                        syncId: card.reviewCardID
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

    private func recordIdentifiers(_ record: LocalCardRecord) -> Set<String> {
        var identifiers = Set([record.id.lowercased()])
        if let card = decodeCard(record: record) {
            identifiers.formUnion(StudyCardIdentity.identifiers(for: card))
        }
        return identifiers
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

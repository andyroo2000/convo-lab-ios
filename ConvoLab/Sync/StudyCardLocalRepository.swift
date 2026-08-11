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
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for (index, card) in cards.enumerated() {
            let payload = try StorageCodec.encoder.encode(card)
            if let record = byID[card.id] {
                record.isInActiveSession = true
                // Queue membership and position are server/session metadata, so
                // keep them current even while local card content remains dirty.
                record.queueIndex = index
                guard record.locallyUpdatedAt == nil else { continue }
                record.payload = payload
                record.serverUpdatedAt = card.updatedAt
            } else {
                context.insert(LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: index,
                    payload: payload
                ))
            }
        }
        try context.save()
    }

    func mergeOfflineReserve(_ cards: [StudyCard], userID: Int) throws {
        let existing = try records(userID: userID)
        let byID = Dictionary(
            existing.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for (index, card) in cards.enumerated() {
            let payload = try StorageCodec.encoder.encode(card)
            if let record = byID[card.id.lowercased()] {
                record.queueIndex = index
                guard record.locallyUpdatedAt == nil else { continue }
                record.payload = payload
                record.serverUpdatedAt = card.updatedAt
            } else {
                let record = LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: index,
                    payload: payload
                )
                record.isInActiveSession = false
                context.insert(record)
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
        let cardsByID = Dictionary(
            cards.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for record in try records(userID: userID) {
            guard let card = cardsByID[record.id] else {
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
}

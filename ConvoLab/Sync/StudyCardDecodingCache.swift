import Foundation

/// Retains value snapshots rather than SwiftData models, whose fetch lifetimes vary.
@MainActor
final class StudyCardDecodingCache {
    private struct Entry {
        let payload: Data
        let card: StudyCard
    }

    private var userID: Int?
    private var entries: [String: Entry] = [:]
    private let decode: (Data) throws -> StudyCard

    init(decode: @escaping (Data) throws -> StudyCard = {
        try StorageCodec.decoder.decode(StudyCard.self, from: $0)
    }) {
        self.decode = decode
    }

    // No actor-bound teardown is needed. Swift 6.2 can crash in its generated
    // isolated destructor outside a task (swiftlang/swift issue #87316).
    nonisolated deinit {}

    func card(from record: LocalCardRecord) throws -> StudyCard {
        selectAccount(record.userID)
        let payload = record.payload
        if let entry = entries[record.id], entry.payload == payload {
            return entry.card
        }
        // Raw writes and rollback may bypass repository mutation methods. Never
        // trust timestamps or retain an old value when replacement bytes fail.
        entries.removeValue(forKey: record.id)
        let card = try decode(payload)
        entries[record.id] = Entry(payload: payload, card: card)
        return card
    }

    func selectAccount(_ userID: Int) {
        guard self.userID != userID else { return }
        clear()
        self.userID = userID
    }

    func retainOnly(recordIDs: Set<String>, userID: Int) {
        selectAccount(userID)
        entries = entries.filter { recordIDs.contains($0.key) }
    }

    func clear() {
        userID = nil
        entries.removeAll()
    }
}

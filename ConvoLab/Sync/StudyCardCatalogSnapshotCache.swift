import Foundation

nonisolated struct StudyCardCatalogSnapshot: Codable, Sendable {
    let savedAt: Date
    let newCardQueue: [StudyNewCardQueueItem]
    let newCardQueueTotal: Int
    let newCardQueueNextCursor: String?
    let newCardQueueRefreshedAt: Date?
    let learningItems: [StudyLearningItem]
    let learningItemsNextCursor: String?
    let learningItemsRefreshedAt: Date?
    let manualDrafts: [StudyManualCardDraft]
    let manualDraftsRefreshedAt: Date?
}

@MainActor
final class StudyCardCatalogSnapshotCache {
    private let defaults: UserDefaults
    private let keyPrefix = "study-card-catalog-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userID: Int) -> StudyCardCatalogSnapshot? {
        guard let data = defaults.data(forKey: key(userID: userID)) else { return nil }
        return try? StorageCodec.decoder.decode(StudyCardCatalogSnapshot.self, from: data)
    }

    func save(_ snapshot: StudyCardCatalogSnapshot, userID: Int) {
        guard let data = try? StorageCodec.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key(userID: userID))
    }

    func remove(userID: Int) {
        defaults.removeObject(forKey: key(userID: userID))
    }

    private func key(userID: Int) -> String {
        "\(keyPrefix).\(userID)"
    }
}

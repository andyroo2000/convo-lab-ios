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
}

nonisolated struct StudyManualDraftSnapshot: Codable, Sendable {
    let savedAt: Date
    let drafts: [StudyManualCardDraft]
    let refreshedAt: Date?
}

@MainActor
final class StudyCardCatalogSnapshotCache {
    private let defaults: UserDefaults
    private let catalogKeyPrefix = "study-card-catalog-v1"
    private let manualDraftKeyPrefix = "study-manual-drafts-v1"
    private let offlineReserveKeyPrefix = "study-offline-reserve-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userID: Int) -> StudyCardCatalogSnapshot? {
        guard let data = defaults.data(forKey: catalogKey(userID: userID)) else { return nil }
        return try? StorageCodec.decoder.decode(StudyCardCatalogSnapshot.self, from: data)
    }

    func save(_ snapshot: StudyCardCatalogSnapshot, userID: Int) {
        guard let data = try? StorageCodec.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: catalogKey(userID: userID))
    }

    func loadManualDrafts(userID: Int) -> StudyManualDraftSnapshot? {
        guard let data = defaults.data(forKey: manualDraftKey(userID: userID)) else { return nil }
        return try? StorageCodec.decoder.decode(StudyManualDraftSnapshot.self, from: data)
    }

    func saveManualDrafts(_ snapshot: StudyManualDraftSnapshot, userID: Int) {
        guard let data = try? StorageCodec.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: manualDraftKey(userID: userID))
    }

    func loadOfflineReserveMetadata(userID: Int) -> StudyOfflineReserveMetadata? {
        guard let data = defaults.data(forKey: offlineReserveKey(userID: userID)) else {
            return nil
        }
        return try? StorageCodec.decoder.decode(StudyOfflineReserveMetadata.self, from: data)
    }

    func saveOfflineReserveMetadata(
        _ metadata: StudyOfflineReserveMetadata,
        userID: Int
    ) {
        guard let data = try? StorageCodec.encoder.encode(metadata) else { return }
        defaults.set(data, forKey: offlineReserveKey(userID: userID))
    }

    func remove(userID: Int) {
        defaults.removeObject(forKey: catalogKey(userID: userID))
        defaults.removeObject(forKey: manualDraftKey(userID: userID))
        defaults.removeObject(forKey: offlineReserveKey(userID: userID))
    }

    private func catalogKey(userID: Int) -> String {
        "\(catalogKeyPrefix).\(userID)"
    }

    private func manualDraftKey(userID: Int) -> String {
        "\(manualDraftKeyPrefix).\(userID)"
    }

    private func offlineReserveKey(userID: Int) -> String {
        "\(offlineReserveKeyPrefix).\(userID)"
    }
}

import Foundation
import SwiftData

@Observable
final class DailyAudioStore {
    private let api: APIClient
    private let context: ModelContext
    private let mediaCache: MediaCache

    private(set) var practices: [DailyAudioPractice] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(api: APIClient, context: ModelContext, mediaCache: MediaCache) {
        self.api = api
        self.context = context
        self.mediaCache = mediaCache
        loadLocal()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: [DailyAudioPractice] = try await api.request(
                "/api/daily-audio-practice"
            )
            practices = response.sorted { $0.createdAt > $1.createdAt }
            try persist(practices)
        } catch {
            if practices.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func create() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: DailyAudioPractice = try await api.request(
                "/api/daily-audio-practice",
                method: "POST",
                body: CreateDailyAudioRequest(
                    timeZone: TimeZone.current.identifier,
                    targetDurationMinutes: 30
                )
            )
            practices.removeAll { $0.id == response.id }
            practices.insert(response, at: 0)
            try persist([response])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ practice: DailyAudioPractice) async {
        let urls = practice.tracks.compactMap(\.audioUrl).compactMap(URL.init(string:))
        await mediaCache.prepare(urls: urls, category: "daily-audio")
    }

    func playableURL(for track: DailyAudioTrack) -> URL? {
        guard let raw = track.audioUrl, let remote = URL(string: raw) else { return nil }
        return mediaCache.localURL(for: remote) ?? remote
    }

    private func persist(_ practices: [DailyAudioPractice]) throws {
        let existing = try context.fetch(FetchDescriptor<LocalDailyAudioPractice>())
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for practice in practices {
            let payload = try StorageCodec.encoder.encode(practice)
            if let record = byID[practice.id] {
                record.payload = payload
                record.status = practice.status
                record.updatedAt = practice.updatedAt
            } else {
                context.insert(LocalDailyAudioPractice(practice: practice, payload: payload))
            }
        }
        try context.save()
    }

    private func loadLocal() {
        let descriptor = FetchDescriptor<LocalDailyAudioPractice>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        practices = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(DailyAudioPractice.self, from: $0.payload)
        }
    }
}

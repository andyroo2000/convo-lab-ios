import Foundation
import SwiftData

@Observable
final class DailyAudioStore {
    private let api: APIClient
    private let context: ModelContext
    private let mediaCache: MediaCache
    @ObservationIgnored private var activeUserID: Int?

    private(set) var practices: [DailyAudioPractice] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(
        initialUserID: Int? = nil,
        api: APIClient,
        context: ModelContext,
        mediaCache: MediaCache
    ) {
        self.api = api
        self.context = context
        self.mediaCache = mediaCache
        if let initialUserID {
            activate(userID: initialUserID)
        }
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        mediaCache.activate(userID: userID)
        errorMessage = nil
        loadLocal(userID: userID)
    }

    func deactivate() {
        activeUserID = nil
        practices = []
        errorMessage = nil
        isLoading = false
    }

    func refresh() async {
        guard let userID = activeUserID else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // learning-os deliberately resolves the resource collection directly for
            // ConvoLab compatibility; this endpoint does not use Laravel's data envelope.
            let response: [DailyAudioPractice] = try await api.request(
                "/api/daily-audio-practice"
            )
            guard activeUserID == userID else { return }
            practices = response.sorted { $0.createdAt > $1.createdAt }
            try persist(practices, userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create() async {
        guard let userID = activeUserID else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // The create endpoint shares the direct compatibility payload used by list/show.
            let response: DailyAudioPractice = try await api.request(
                "/api/daily-audio-practice",
                method: "POST",
                body: CreateDailyAudioRequest(
                    timeZone: TimeZone.current.identifier,
                    targetDurationMinutes: 30
                )
            )
            guard activeUserID == userID else { return }
            practices.removeAll { $0.id == response.id }
            practices.insert(response, at: 0)
            try persist([response], userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ practice: DailyAudioPractice) async {
        for track in practice.tracks {
            guard let raw = track.audioUrl, let remote = URL(string: raw) else { continue }
            do {
                let cacheKey = cacheKey(for: track)
                _ = try await mediaCache.download(
                    remote,
                    category: "daily-audio",
                    cacheKey: cacheKey
                )
                try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func playableURL(for track: DailyAudioTrack) async -> URL? {
        guard let raw = track.audioUrl, let remote = URL(string: raw) else { return nil }
        let cacheKey = cacheKey(for: track)
        if let local = mediaCache.localURL(for: remote, cacheKey: cacheKey) {
            return local
        }
        do {
            let local = try await mediaCache.download(
                remote,
                category: "daily-audio",
                cacheKey: cacheKey
            )
            try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
            return local
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func cacheKey(for track: DailyAudioTrack) -> String {
        // learning-os advances the track's updatedAt on every regeneration
        // transition (reset, generation claim, and ready), making it the
        // canonical asset revision for client caches.
        let revision = Int64((track.updatedAt.timeIntervalSince1970 * 1_000).rounded())
        return "daily-audio:\(track.id):\(revision)"
    }

    private func removePreviousCachedRevisions(
        of track: DailyAudioTrack,
        keeping cacheKey: String
    ) throws {
        try mediaCache.removeCachedItems(
            category: "daily-audio",
            // The prefix intentionally omits the revision separator so it also
            // retires the unversioned key written by older app builds.
            cacheKeyPrefix: "daily-audio:\(track.id)",
            keeping: cacheKey
        )
    }

    private func persist(_ practices: [DailyAudioPractice], userID: Int) throws {
        let existing = try context.fetch(
            FetchDescriptor<LocalDailyAudioPractice>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for practice in practices {
            let payload = try StorageCodec.encoder.encode(practice)
            if let record = byID[practice.id] {
                record.payload = payload
                record.status = practice.status
                record.updatedAt = practice.updatedAt
            } else {
                context.insert(LocalDailyAudioPractice(
                    practice: practice,
                    userID: userID,
                    payload: payload
                ))
            }
        }
        try context.save()
    }

    private func loadLocal(userID: Int) {
        let descriptor = FetchDescriptor<LocalDailyAudioPractice>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        practices = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(DailyAudioPractice.self, from: $0.payload)
        }
    }
}

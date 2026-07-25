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
    private(set) var isLoadingMore = false
    private(set) var total = 0
    private(set) var nextCursor: String?
    private(set) var errorMessage: String?

    var hasMore: Bool {
        nextCursor != nil
    }

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
        total = practices.count
    }

    func deactivate() {
        activeUserID = nil
        practices = []
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
        total = 0
        nextCursor = nil
    }

    func deleteLocalData(userID: Int) throws {
        if activeUserID == userID {
            deactivate()
        }
        let records = try context.fetch(
            FetchDescriptor<LocalDailyAudioPractice>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        records.forEach(context.delete)
        try context.save()
    }

    func refresh() async {
        guard let userID = activeUserID else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: DailyAudioPracticePage = try await api.request(
                "/api/daily-audio-practice",
                query: [
                    URLQueryItem(name: "paginated", value: "1"),
                    URLQueryItem(name: "cursor", value: "0"),
                    URLQueryItem(name: "limit", value: "14"),
                ]
            )
            guard activeUserID == userID else { return }
            practices = orderedPractices(response.items)
            total = response.total
            nextCursor = response.nextCursor
            try persist(response.items, userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard
            let userID = activeUserID,
            let cursor = nextCursor,
            !isLoading,
            !isLoadingMore
        else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response: DailyAudioPracticePage = try await api.request(
                "/api/daily-audio-practice",
                query: [
                    URLQueryItem(name: "paginated", value: "1"),
                    URLQueryItem(name: "cursor", value: cursor),
                    URLQueryItem(name: "limit", value: "14"),
                ]
            )
            guard activeUserID == userID else { return }
            let existingIDs = Set(practices.map(\.id))
            practices.append(contentsOf: response.items.filter { !existingIDs.contains($0.id) })
            practices = orderedPractices(practices)
            total = response.total
            nextCursor = response.nextCursor
            try persist(response.items, userID: userID)
            errorMessage = nil
        } catch {
            guard activeUserID == userID else { return }
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
            let wasAlreadyLoaded = practices.contains { $0.id == response.id }
            practices.removeAll { $0.id == response.id }
            practices.insert(response, at: 0)
            if !wasAlreadyLoaded {
                total += 1
            }
            try persist([response], userID: userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ practice: DailyAudioPractice) async {
        guard
            let userID = activeUserID,
            practices.contains(where: { $0.id == practice.id })
        else {
            return
        }
        for track in practice.tracks {
            guard activeUserID == userID else { return }
            guard let raw = track.audioUrl, let remote = URL(string: raw) else { continue }
            do {
                let cacheKey = cacheKey(for: track)
                _ = try await mediaCache.download(
                    remote,
                    category: "daily-audio",
                    cacheKey: cacheKey
                )
                guard activeUserID == userID else { return }
                try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
            } catch {
                guard activeUserID == userID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func detailedTrack(for track: DailyAudioTrack) async -> DailyAudioTrack? {
        guard
            let userID = activeUserID,
            practices.contains(where: { $0.id == track.practiceId })
        else {
            return nil
        }
        if track.scriptUnitsJson != nil, track.timingData != nil {
            return track
        }
        if let persisted = persistedTrack(
            id: track.id,
            practiceID: track.practiceId,
            userID: userID
        ), persisted.scriptUnitsJson != nil, persisted.timingData != nil {
            return persisted
        }

        do {
            let practice: DailyAudioPractice = try await api.request(
                "/api/daily-audio-practice/\(track.practiceId)"
            )
            guard
                activeUserID == userID,
                practice.id == track.practiceId,
                let detailedTrack = practice.tracks.first(where: { $0.id == track.id })
            else {
                return nil
            }
            practices.removeAll { $0.id == practice.id }
            practices.append(practice)
            practices = orderedPractices(practices)
            try persist([practice], userID: userID)
            return detailedTrack
        } catch {
            guard activeUserID == userID else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func playableURL(for track: DailyAudioTrack) async -> URL? {
        guard
            let userID = activeUserID,
            practices.contains(where: { practice in
                practice.tracks.contains(where: { $0.id == track.id })
            })
        else {
            return nil
        }
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
            guard activeUserID == userID else { return nil }
            try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
            return local
        } catch {
            guard activeUserID == userID else { return nil }
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
            if let record = byID[practice.id] {
                let cached = try? StorageCodec.decoder.decode(
                    DailyAudioPractice.self,
                    from: record.payload
                )
                let payload = try StorageCodec.encoder.encode(
                    practice.preservingTrackDetails(from: cached)
                )
                record.payload = payload
                record.status = practice.status
                record.updatedAt = practice.updatedAt
            } else {
                let payload = try StorageCodec.encoder.encode(practice)
                context.insert(LocalDailyAudioPractice(
                    practice: practice,
                    userID: userID,
                    payload: payload
                ))
            }
        }
        try context.save()
    }

    private func persistedTrack(
        id: String,
        practiceID: String,
        userID: Int
    ) -> DailyAudioTrack? {
        let descriptor = FetchDescriptor<LocalDailyAudioPractice>(
            predicate: #Predicate {
                $0.userID == userID && $0.id == practiceID
            }
        )
        guard
            let record = try? context.fetch(descriptor).first,
            let practice = try? StorageCodec.decoder.decode(
                DailyAudioPractice.self,
                from: record.payload
            )
        else {
            return nil
        }
        return practice.tracks.first { $0.id == id }
    }

    private func loadLocal(userID: Int) {
        let descriptor = FetchDescriptor<LocalDailyAudioPractice>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        practices = ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(DailyAudioPractice.self, from: $0.payload)
        }
        practices = orderedPractices(practices)
    }

    private func orderedPractices(
        _ values: [DailyAudioPractice]
    ) -> [DailyAudioPractice] {
        values.sorted {
            if $0.practiceDate != $1.practiceDate {
                return $0.practiceDate > $1.practiceDate
            }
            return $0.id > $1.id
        }
    }
}

private extension DailyAudioPractice {
    func preservingTrackDetails(
        from cached: DailyAudioPractice?
    ) -> DailyAudioPractice {
        guard let cached else { return self }
        let cachedByID = Dictionary(
            uniqueKeysWithValues: cached.tracks.map { ($0.id, $0) }
        )
        let mergedTracks = tracks.map { track in
            guard
                track.scriptUnitsJson == nil,
                track.timingData == nil,
                let previous = cachedByID[track.id],
                previous.updatedAt == track.updatedAt
            else {
                return track
            }
            return DailyAudioTrack(
                id: track.id,
                practiceId: track.practiceId,
                mode: track.mode,
                status: track.status,
                title: track.title,
                sortOrder: track.sortOrder,
                scriptUnitsJson: previous.scriptUnitsJson,
                audioUrl: track.audioUrl,
                timingData: previous.timingData,
                approxDurationSeconds: track.approxDurationSeconds,
                updatedAt: track.updatedAt
            )
        }
        return DailyAudioPractice(
            id: id,
            practiceDate: practiceDate,
            status: status,
            targetDurationMinutes: targetDurationMinutes,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tracks: mergedTracks
        )
    }
}

import Foundation
import SwiftData

@Observable
final class DailyAudioStore {
    private enum ErrorSource: Equatable {
        case refresh
        case loadMore
        case create
        case download(String)
        case playback(String)
    }

    private let api: APIClient
    private let context: ModelContext
    private let mediaCache: MediaCache
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var activationGeneration = 0
    @ObservationIgnored private var generationPollingTask: Task<Void, Never>?
    @ObservationIgnored private var generationPollingID: UUID?
    @ObservationIgnored private var errorSource: ErrorSource?

    private(set) var practices: [DailyAudioPractice] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var total = 0
    private(set) var nextCursor: String?
    private(set) var errorMessage: String?
    private(set) var generationStartWasInterrupted = false
    private(set) var lastRefreshAt: Date?
    private(set) var downloadedTrackIDs: Set<String> = []
    private(set) var downloadingTrackIDs: Set<String> = []
    private(set) var practiceDownloadProgress: [String: Double] = [:]

    var hasMore: Bool {
        nextCursor != nil
    }

    var isPracticeDownloadInProgress: Bool {
        !practiceDownloadProgress.isEmpty
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
        activationGeneration += 1
        generationPollingTask?.cancel()
        generationPollingTask = nil
        generationPollingID = nil
        activeUserID = userID
        mediaCache.activate(userID: userID)
        errorMessage = nil
        errorSource = nil
        generationStartWasInterrupted = false
        lastRefreshAt = nil
        isLoading = false
        isLoadingMore = false
        downloadingTrackIDs = []
        practiceDownloadProgress = [:]
        loadLocal(userID: userID)
        total = practices.count
        refreshDownloadedTrackIDs(for: practices, replacingExisting: true)
        beginGenerationPollingIfNeeded()
    }

    func deactivate() {
        activationGeneration += 1
        activeUserID = nil
        generationPollingTask?.cancel()
        generationPollingTask = nil
        generationPollingID = nil
        practices = []
        errorMessage = nil
        errorSource = nil
        generationStartWasInterrupted = false
        lastRefreshAt = nil
        isLoading = false
        isLoadingMore = false
        total = 0
        nextCursor = nil
        downloadedTrackIDs = []
        downloadingTrackIDs = []
        practiceDownloadProgress = [:]
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

    @discardableResult
    func refresh(showsErrors: Bool = true) async -> Bool {
        let requestedUserID = activeUserID
        let requestedGeneration = activationGeneration
        while showsErrors, isLoading || isLoadingMore {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
            guard activeUserID == requestedUserID,
                  activationGeneration == requestedGeneration
            else { return false }
        }
        guard
            let userID = activeUserID,
            !isLoading,
            !isLoadingMore
        else {
            return false
        }
        let operationGeneration = activationGeneration
        isLoading = true
        if showsErrors {
            clearError(from: .refresh)
        }
        defer {
            if isCurrentActivation(userID, generation: operationGeneration) {
                isLoading = false
            }
        }
        do {
            let response: DailyAudioPracticePage = try await api.request(
                "/api/daily-audio-practice",
                query: [
                    URLQueryItem(name: "paginated", value: "1"),
                    URLQueryItem(name: "cursor", value: "0"),
                    URLQueryItem(name: "limit", value: "14"),
                ]
            )
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return false }
            practices = orderedPractices(response.items)
            total = response.total
            nextCursor = response.nextCursor
            try persist(response.items, userID: userID)
            refreshDownloadedTrackIDs(for: practices, replacingExisting: true)
            generationStartWasInterrupted = false
            lastRefreshAt = .now
            beginGenerationPollingIfNeeded()
            clearError(from: .refresh)
            return true
        } catch {
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return false }
            if showsErrors {
                if Self.isCancellation(error) {
                    setError(practices.contains(where: { $0.status == "generating" })
                        ? "Refresh was interrupted. Audio generation continues on the server."
                        : "Daily Audio refresh was interrupted. Try again.", from: .refresh)
                } else {
                    setError(error.localizedDescription, from: .refresh)
                }
            }
            return false
        }
    }

    func refreshIfNeeded(maxAge: Duration) async {
        guard !isLoading, !isLoadingMore else { return }
        let components = maxAge.components
        let maxAgeSeconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        if let lastRefreshAt,
           Date.now.timeIntervalSince(lastRefreshAt) < maxAgeSeconds {
            return
        }
        await refresh(showsErrors: false)
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
        let operationGeneration = activationGeneration
        isLoadingMore = true
        defer {
            if isCurrentActivation(userID, generation: operationGeneration) {
                isLoadingMore = false
            }
        }

        do {
            let response: DailyAudioPracticePage = try await api.request(
                "/api/daily-audio-practice",
                query: [
                    URLQueryItem(name: "paginated", value: "1"),
                    URLQueryItem(name: "cursor", value: cursor),
                    URLQueryItem(name: "limit", value: "14"),
                ]
            )
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return }
            let existingIDs = Set(practices.map(\.id))
            let newPractices = response.items.filter { !existingIDs.contains($0.id) }
            practices.append(contentsOf: newPractices)
            practices = orderedPractices(practices)
            total = response.total
            nextCursor = response.nextCursor
            try persist(response.items, userID: userID)
            refreshDownloadedTrackIDs(for: newPractices)
            clearError(from: .loadMore)
        } catch {
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return }
            setError(error.localizedDescription, from: .loadMore)
        }
    }

    func create() async {
        guard
            let userID = activeUserID,
            !isLoading,
            !isLoadingMore
        else {
            return
        }
        let operationGeneration = activationGeneration
        isLoading = true
        clearError(from: .create)
        defer {
            if isCurrentActivation(userID, generation: operationGeneration) {
                isLoading = false
            }
        }
        do {
            // The backend upserts by user and practice date, so retrying an interrupted
            // response requeues today's existing practice rather than creating a duplicate.
            let response: DailyAudioPractice = try await api.request(
                "/api/daily-audio-practice",
                method: "POST",
                body: CreateDailyAudioRequest(
                    timeZone: TimeZone.current.identifier,
                    targetDurationMinutes: 30
                )
            )
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return }
            let wasAlreadyLoaded = practices.contains { $0.id == response.id }
            practices.removeAll { $0.id == response.id }
            practices.insert(response, at: 0)
            if !wasAlreadyLoaded {
                total += 1
            }
            try persist([response], userID: userID)
            refreshDownloadedTrackIDs(for: [response])
            generationStartWasInterrupted = false
            beginGenerationPollingIfNeeded()
            clearError(from: .create)
        } catch {
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return }
            if Self.isCancellation(error) {
                generationStartWasInterrupted = true
                setError("Generation was interrupted. You can retry it.", from: .create)
            } else {
                setError(error.localizedDescription, from: .create)
            }
        }
    }

    func download(_ practice: DailyAudioPractice) async {
        guard
            let userID = activeUserID,
            practices.contains(where: { $0.id == practice.id }),
            practiceDownloadProgress.isEmpty,
            !isDownloaded(practice)
        else {
            return
        }
        let operationGeneration = activationGeneration
        let downloadableTracks = downloadableTracks(in: practice)
        guard !downloadableTracks.isEmpty else { return }
        clearError(from: .download(practice.id))
        refreshDownloadedTrackIDs(for: [practice])
        updateDownloadProgress(for: practice.id, tracks: downloadableTracks)
        defer {
            if isCurrentActivation(userID, generation: operationGeneration) {
                downloadingTrackIDs.subtract(downloadableTracks.map(\.id))
                practiceDownloadProgress[practice.id] = nil
            }
        }

        let pendingTracks = downloadableTracks.filter { !downloadedTrackIDs.contains($0.id) }
        downloadingTrackIDs.formUnion(pendingTracks.map(\.id))
        var firstError: String?
        let downloadTasks = pendingTracks.map { track in
            Task { @MainActor [weak self] in
                guard let self else { return (track, nil as String?) }
                guard isCurrentActivation(
                    userID,
                    generation: operationGeneration
                ) else { return (track, nil) }
                guard let raw = track.audioUrl, let remote = URL(string: raw) else {
                    downloadingTrackIDs.remove(track.id)
                    updateDownloadProgress(for: practice.id, tracks: downloadableTracks)
                    return (track, "The audio download URL is invalid.")
                }
                let downloadError: String?
                do {
                    let cacheKey = cacheKey(for: track)
                    _ = try await mediaCache.download(
                        remote,
                        category: "daily-audio",
                        cacheKey: cacheKey
                    )
                    guard isCurrentActivation(
                        userID,
                        generation: operationGeneration
                    ) else { return (track, nil) }
                    try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
                    downloadedTrackIDs.insert(track.id)
                    downloadError = nil
                } catch {
                    downloadError = Self.isCancellation(error) ? nil : error.localizedDescription
                }
                guard isCurrentActivation(
                    userID,
                    generation: operationGeneration
                ) else { return (track, nil) }
                downloadingTrackIDs.remove(track.id)
                updateDownloadProgress(for: practice.id, tracks: downloadableTracks)
                return (track, downloadError)
            }
        }
        for task in downloadTasks {
            let (_, downloadError) = await task.value
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return }
            if let downloadError {
                firstError = firstError ?? downloadError
            }
        }
        if let firstError {
            setError(firstError, from: .download(practice.id))
        } else {
            clearError(from: .download(practice.id))
        }
    }

    func isDownloaded(_ track: DailyAudioTrack) -> Bool {
        downloadedTrackIDs.contains(track.id)
    }

    func isDownloading(_ track: DailyAudioTrack) -> Bool {
        downloadingTrackIDs.contains(track.id)
    }

    func isDownloaded(_ practice: DailyAudioPractice) -> Bool {
        let downloadableTracks = downloadableTracks(in: practice)
        return !downloadableTracks.isEmpty
            && downloadableTracks.allSatisfy { downloadedTrackIDs.contains($0.id) }
    }

    func detailedTrack(for track: DailyAudioTrack) async -> DailyAudioTrack? {
        guard
            let userID = activeUserID,
            practices.contains(where: { $0.id == track.practiceId })
        else {
            return nil
        }
        let operationGeneration = activationGeneration
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
                isCurrentActivation(userID, generation: operationGeneration),
                practice.id == track.practiceId,
                let detailedTrack = practice.tracks.first(where: { $0.id == track.id })
            else {
                return nil
            }
            practices.removeAll { $0.id == practice.id }
            practices.append(practice)
            practices = orderedPractices(practices)
            try persist([practice], userID: userID)
            clearError(from: .playback(track.id))
            return detailedTrack
        } catch {
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return nil }
            setError(error.localizedDescription, from: .playback(track.id))
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
        let operationGeneration = activationGeneration
        guard let raw = track.audioUrl, let remote = URL(string: raw) else { return nil }
        let cacheKey = cacheKey(for: track)
        if let local = mediaCache.localURL(for: remote, cacheKey: cacheKey) {
            downloadedTrackIDs.insert(track.id)
            clearError(from: .playback(track.id))
            return local
        }
        downloadingTrackIDs.insert(track.id)
        defer {
            if isCurrentActivation(userID, generation: operationGeneration) {
                downloadingTrackIDs.remove(track.id)
            }
        }
        do {
            let local = try await mediaCache.download(
                remote,
                category: "daily-audio",
                cacheKey: cacheKey
            )
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return nil }
            try? removePreviousCachedRevisions(of: track, keeping: cacheKey)
            downloadedTrackIDs.insert(track.id)
            return local
        } catch {
            guard isCurrentActivation(
                userID,
                generation: operationGeneration
            ) else { return nil }
            setError(error.localizedDescription, from: .playback(track.id))
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

    private func downloadableTracks(in practice: DailyAudioPractice) -> [DailyAudioTrack] {
        practice.tracks.filter {
            $0.status == "ready" && $0.audioUrl.flatMap(URL.init(string:)) != nil
        }
    }

    private func refreshDownloadedTrackIDs(
        for practices: [DailyAudioPractice],
        replacingExisting: Bool = false
    ) {
        if replacingExisting {
            downloadedTrackIDs.removeAll()
        } else {
            downloadedTrackIDs.subtract(practices.flatMap(\.tracks).map(\.id))
        }
        let tracksAndKeys = practices
            .flatMap(\.tracks)
            .filter { $0.audioUrl.flatMap(URL.init(string:)) != nil }
            .map { (track: $0, cacheKey: cacheKey(for: $0)) }
        let cachedKeys = mediaCache.cachedKeys(
            forCacheKeys: Set(tracksAndKeys.map { $0.cacheKey })
        )
        for item in tracksAndKeys where cachedKeys.contains(item.cacheKey) {
            downloadedTrackIDs.insert(item.track.id)
        }
    }

    private func updateDownloadProgress(
        for practiceID: String,
        tracks: [DailyAudioTrack]
    ) {
        guard !tracks.isEmpty else {
            practiceDownloadProgress[practiceID] = nil
            return
        }
        let completed = tracks.filter { downloadedTrackIDs.contains($0.id) }.count
        practiceDownloadProgress[practiceID] = Double(completed) / Double(tracks.count)
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

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    private func beginGenerationPollingIfNeeded() {
        guard let userID = activeUserID,
              generationPollingTask == nil,
              practices.contains(where: { $0.status == "generating" })
        else {
            return
        }
        let operationGeneration = activationGeneration
        let pollingID = UUID()
        generationPollingID = pollingID
        generationPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generationPollingID == pollingID {
                    generationPollingTask = nil
                    generationPollingID = nil
                }
            }
            var delay: TimeInterval = 5
            while !Task.isCancelled,
                  isCurrentActivation(userID, generation: operationGeneration),
                  practices.contains(where: { $0.status == "generating" }) {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let refreshed = await refresh(showsErrors: false)
                delay = refreshed ? 5 : min(delay * 2, 60)
            }
        }
    }

    private func isCurrentActivation(_ userID: Int, generation: Int) -> Bool {
        activeUserID == userID && activationGeneration == generation
    }

    private func setError(_ message: String, from source: ErrorSource) {
        errorMessage = message
        errorSource = source
    }

    private func clearError(from source: ErrorSource) {
        guard errorSource == source else { return }
        errorMessage = nil
        errorSource = nil
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

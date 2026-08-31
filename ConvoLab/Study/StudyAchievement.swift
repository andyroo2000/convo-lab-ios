import Foundation

nonisolated struct StudyAchievementAsset: Codable, Equatable, Sendable {
    let path: String
    let width: Int
    let height: Int
}

nonisolated struct StudyAchievementPNGAssets: Codable, Equatable, Sendable {
    let png: [String: StudyAchievementAsset]
}

nonisolated struct StudyAchievementTierAssets: Codable, Equatable, Sendable {
    let earned: StudyAchievementPNGAssets
    let locked: StudyAchievementPNGAssets
}

nonisolated struct StudyAchievementTier: Codable, Equatable, Sendable {
    let key: String
    let title: String
    let threshold: Int
    let description: String
    let earnedDescription: String
    let assets: StudyAchievementTierAssets
}

nonisolated struct StudyAchievementFamily: Codable, Equatable, Sendable {
    let key: String
    let title: String
    let metricKey: String
    let unit: String
    let hiddenUntilEarned: Bool?
    let tiers: [StudyAchievementTier]
}

nonisolated struct StudyAchievementPresentation: Codable, Equatable, Sendable {
    let targetVisibleBadgeCount: Int
    let fillWithLockedCandidates: Bool
    let noDataFallbackTierIds: [String]
}

nonisolated struct StudyAchievementCatalog: Codable, Equatable, Sendable {
    let revision: String
    let presentation: StudyAchievementPresentation
    let families: [StudyAchievementFamily]

    func validated() throws -> Self {
        guard !revision.isEmpty,
              presentation.targetVisibleBadgeCount > 0,
              !families.isEmpty
        else {
            throw StudyAchievementCatalogError.invalidStructure
        }

        var familyKeys = Set<String>()
        var metricKeys = Set<String>()
        var tierIDs = Set<String>()
        for family in families {
            guard !family.key.isEmpty,
                  !family.title.isEmpty,
                  !family.metricKey.isEmpty,
                  !family.unit.isEmpty,
                  !family.tiers.isEmpty,
                  familyKeys.insert(family.key).inserted,
                  metricKeys.insert(family.metricKey).inserted
            else {
                throw StudyAchievementCatalogError.invalidStructure
            }

            var previousThreshold = 0
            for tier in family.tiers {
                let id = "\(family.key).\(tier.key)"
                guard !tier.key.isEmpty,
                      !tier.title.isEmpty,
                      !tier.description.isEmpty,
                      !tier.earnedDescription.isEmpty,
                      tier.threshold > previousThreshold,
                      tierIDs.insert(id).inserted
                else {
                    throw StudyAchievementCatalogError.invalidStructure
                }
                try Self.validate(asset: tier.assets.earned.png["256"], size: 256)
                try Self.validate(asset: tier.assets.earned.png["512"], size: 512)
                try Self.validate(asset: tier.assets.locked.png["256"], size: 256)
                try Self.validate(asset: tier.assets.locked.png["512"], size: 512)
                previousThreshold = tier.threshold
            }
        }

        let fallbackIDs = presentation.noDataFallbackTierIds
        guard fallbackIDs.count >= presentation.targetVisibleBadgeCount,
              Set(fallbackIDs).count == fallbackIDs.count,
              fallbackIDs.allSatisfy(tierIDs.contains)
        else {
            throw StudyAchievementCatalogError.invalidStructure
        }
        return self
    }

    private static func validate(asset: StudyAchievementAsset?, size: Int) throws {
        guard let asset,
              asset.width == size,
              asset.height == size,
              asset.path.hasPrefix("/achievement-assets/"),
              !asset.path.contains("..")
        else {
            throw StudyAchievementCatalogError.invalidAsset
        }
    }

    var offlineImageAssets: [StudyAchievementAsset] {
        var seenPaths = Set<String>()
        return families.flatMap(\.tiers).flatMap { tier in
            [tier.assets.earned.png["512"], tier.assets.locked.png["512"]]
                .compactMap { $0 }
        }
        .filter { seenPaths.insert($0.path).inserted }
    }
}

nonisolated enum StudyAchievementCatalogError: Error, Equatable {
    case invalidStructure
    case invalidAsset
}

nonisolated struct StudyAchievementProgress: Codable, Equatable, Sendable {
    let revision: String
    let metricValues: [String: Int]
    let awards: [StudyAchievementAward]

    func validated() throws -> Self {
        let awardIDs = awards.map(\.id)
        guard !revision.isEmpty,
              metricValues.allSatisfy({ !$0.key.isEmpty && $0.value >= 0 }),
              awards.allSatisfy({ !$0.id.isEmpty && $0.earnedAt.timeIntervalSinceReferenceDate.isFinite }),
              Set(awardIDs).count == awardIDs.count
        else {
            throw StudyAchievementCatalogError.invalidStructure
        }
        return self
    }
}

nonisolated struct StudyAchievementAward: Codable, Equatable, Sendable {
    let id: String
    let earnedAt: Date
}

struct StudyAchievementCompletion: Identifiable, Equatable, Sendable {
    let id: UUID
    let records: [StudySessionReviewRecord]
    let newAwardIDs: [String]
    let celebrationPresented: Bool
}

nonisolated struct PresentedStudyAchievement: Identifiable, Equatable, Sendable {
    let family: StudyAchievementFamily
    let tier: StudyAchievementTier
    let isEarned: Bool
    let earnedAt: Date?
    let currentValue: Int?
    let remaining: Int?

    nonisolated var id: String { "\(family.key).\(tier.key)" }

    var imageAsset: StudyAchievementAsset? {
        let assets = isEarned ? tier.assets.earned : tier.assets.locked
        return assets.png["512"]
    }
}

nonisolated enum StudyAchievementPresentationModel {
    nonisolated static func all(
        catalog: StudyAchievementCatalog,
        progress: StudyAchievementProgress?
    ) -> [PresentedStudyAchievement] {
        let compatibleProgress = progress?.revision == catalog.revision ? progress : nil
        let metricValues = compatibleProgress?.metricValues
        let awardsByID = Dictionary(
            (compatibleProgress?.awards ?? []).map { ($0.id, $0.earnedAt) },
            uniquingKeysWith: { _, latest in latest }
        )
        return catalog.families.flatMap { family in
            family.tiers.map { tier in
                let id = "\(family.key).\(tier.key)"
                return present(
                    family: family,
                    tier: tier,
                    metricValues: metricValues,
                    earnedAt: awardsByID[id]
                )
            }
        }
    }

    nonisolated static func recentEarned(
        catalog: StudyAchievementCatalog,
        progress: StudyAchievementProgress?,
        count: Int? = nil
    ) -> [PresentedStudyAchievement] {
        let limit = count ?? catalog.presentation.targetVisibleBadgeCount
        return all(catalog: catalog, progress: progress)
            .filter(\.isEarned)
            .sorted { ($0.earnedAt ?? .distantPast) > ($1.earnedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated static func closestInProgress(
        catalog: StudyAchievementCatalog,
        progress: StudyAchievementProgress?
    ) -> [PresentedStudyAchievement] {
        let achievements = all(catalog: catalog, progress: progress)
        let count = catalog.presentation.targetVisibleBadgeCount
        let compatibleProgress = progress?.revision == catalog.revision ? progress : nil
        let metricValues = compatibleProgress?.metricValues
        let hasProgress = metricValues?.values.contains(where: { $0 > 0 }) == true
            || compatibleProgress?.awards.isEmpty == false

        guard hasProgress else {
            let achievementsByID = Dictionary(
                uniqueKeysWithValues: achievements.map { ($0.id, $0) }
            )
            return catalog.presentation.noDataFallbackTierIds
                .compactMap { achievementsByID[$0] }
                .filter { $0.family.hiddenUntilEarned != true }
                .prefix(count)
                .map { $0 }
        }

        guard catalog.presentation.fillWithLockedCandidates else { return [] }

        let order = Dictionary(
            uniqueKeysWithValues: achievements.enumerated().map { ($0.element.id, $0.offset) }
        )
        let candidates = catalog.families.filter { $0.hiddenUntilEarned != true }.compactMap { family in
            let familyAchievements = achievements.filter { $0.family.key == family.key }
            let highestEarnedIndex = familyAchievements.lastIndex { $0.isEarned }
            return familyAchievements
                .dropFirst((highestEarnedIndex ?? -1) + 1)
                .first { !$0.isEarned }
        }
            .sorted { left, right in
                let leftRatio = Double(left.currentValue ?? 0) / Double(left.tier.threshold)
                let rightRatio = Double(right.currentValue ?? 0) / Double(right.tier.threshold)
                if leftRatio != rightRatio { return leftRatio > rightRatio }
                let leftRemaining = left.remaining ?? left.tier.threshold
                let rightRemaining = right.remaining ?? right.tier.threshold
                if leftRemaining != rightRemaining { return leftRemaining < rightRemaining }
                return order[left.id, default: 0] < order[right.id, default: 0]
            }
        return Array(candidates.prefix(count))
    }

    private nonisolated static func present(
        family: StudyAchievementFamily,
        tier: StudyAchievementTier,
        metricValues: [String: Int]?,
        earnedAt: Date?
    ) -> PresentedStudyAchievement {
        let currentValue = metricValues?[family.metricKey]
        return PresentedStudyAchievement(
            family: family,
            tier: tier,
            isEarned: earnedAt != nil,
            earnedAt: earnedAt,
            currentValue: currentValue,
            remaining: currentValue.map { max(0, tier.threshold - $0) }
        )
    }
}

@MainActor
@Observable
final class StudyAchievementStore {
    private struct CatalogPersistedState: Codable {
        let catalog: StudyAchievementCatalog
        let progress: StudyAchievementProgress?
        let catalogRefreshedAt: Date
        let progressRefreshedAt: Date?
        let evaluatedAt: Date?
    }

    private struct ReviewSession: Codable {
        let id: UUID
        var records: [StudySessionReviewRecord]
        var baselineAwardIDs: [String]?
        var newAwardIDs: [String]
        var isReadyForPresentation: Bool
        var celebrationPresented: Bool
    }

    private struct SessionPersistedState: Codable {
        var activeSession: ReviewSession?
    }

    private static let catalogMaximumAge: TimeInterval = 24 * 60 * 60
    private static let mediaCategory = "achievement-badges"

    private let api: APIClient
    private let mediaCache: MediaCache?
    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let persistenceKeyPrefix = "study-achievements-v1"
    private let sessionKeyPrefix = "study-achievement-sessions-v1"
    private var activeUserID: Int?
    private var catalogRefreshedAt: Date?
    private var progressRefreshedAt: Date?
    private var evaluatedAt: Date?
    private var refreshSequence = 0
    private var assetPreparationSequence = 0
    private var assetPreparationRevision: String?
    private var assetPreparationTask: Task<Void, Never>?

    private(set) var catalog: StudyAchievementCatalog?
    private(set) var progress: StudyAchievementProgress?
    private(set) var cachedAssetURLs: [String: URL] = [:]
    private(set) var preparingAssetPaths: Set<String> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var progressErrorMessage: String?
    private var sessionState = SessionPersistedState()

    init(
        api: APIClient,
        mediaCache: MediaCache? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.api = api
        self.mediaCache = mediaCache
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var inProgressAchievements: [PresentedStudyAchievement] {
        guard let catalog else { return [] }
        return StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: progress
        )
    }

    var earnedAchievements: [PresentedStudyAchievement] {
        guard let catalog else { return [] }
        return StudyAchievementPresentationModel.recentEarned(
            catalog: catalog,
            progress: progress,
            count: .max
        )
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        refreshSequence += 1
        cancelAssetPreparation()
        activeUserID = userID
        restorePersistedState(userID: userID)
        sessionState = loadSessionState(userID: userID)
        errorMessage = nil
        progressErrorMessage = nil
        isLoading = false
        if let catalog {
            startAssetPreparation(for: catalog)
        }
    }

    func deactivate() {
        refreshSequence += 1
        cancelAssetPreparation()
        activeUserID = nil
        catalog = nil
        sessionState = SessionPersistedState()
        progress = nil
        catalogRefreshedAt = nil
        progressRefreshedAt = nil
        evaluatedAt = nil
        cachedAssetURLs = [:]
        preparingAssetPaths = []
        errorMessage = nil
        progressErrorMessage = nil
        isLoading = false
    }

    func refreshIfNeeded(maxAge: TimeInterval = 60, evaluate: Bool = true) async {
        let freshnessDate = evaluate ? evaluatedAt : progressRefreshedAt
        if let freshnessDate, Date.now.timeIntervalSince(freshnessDate) < maxAge {
            return
        }
        await performRefresh(evaluate: evaluate)
    }

    func refresh(evaluate: Bool = true) async {
        let requestedUserID = activeUserID
        let requestedSequence = refreshSequence
        while isLoading {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard activeUserID == requestedUserID,
                  refreshSequence == requestedSequence
            else { return }
        }
        await performRefresh(evaluate: evaluate)
    }

    private func performRefresh(evaluate: Bool) async {
        guard let requestedUserID = activeUserID, !isLoading else { return }
        refreshSequence += 1
        let sequence = refreshSequence
        isLoading = true
        defer {
            if refreshSequence == sequence {
                isLoading = false
            }
        }

        do {
            var validatedCatalog = catalog
            var loadedCatalogRefreshedAt = catalogRefreshedAt
            let catalogIsStale = catalogRefreshedAt.map {
                Date.now.timeIntervalSince($0) >= Self.catalogMaximumAge
            } ?? true
            if validatedCatalog == nil || catalogIsStale {
                do {
                    let loadedCatalog: StudyAchievementCatalog = try await api.request(
                        "/api/achievements/catalog"
                    )
                    validatedCatalog = try loadedCatalog.validated()
                    loadedCatalogRefreshedAt = .now
                } catch {
                    guard validatedCatalog != nil else { throw error }
                    // A saved, validated catalog keeps the shelf useful offline. The
                    // next foreground refresh will retry once the catalog is stale.
                }
            }
            guard !Task.isCancelled,
                  activeUserID == requestedUserID,
                  refreshSequence == sequence,
                  let validatedCatalog
            else { return }

            var loadedProgress = progress?.revision == validatedCatalog.revision ? progress : nil
            var loadedProgressError: String?
            do {
                let response: StudyAchievementProgress = try await api.request(
                    evaluate
                        ? "/api/achievements/evaluate"
                        : "/api/achievements/progress",
                    method: evaluate ? "POST" : "GET"
                )
                let validatedProgress = try response.validated()
                loadedProgress = validatedProgress.revision == validatedCatalog.revision
                    ? validatedProgress
                    : nil
                if loadedProgress == nil {
                    loadedProgressError = "Your badges couldn’t be refreshed right now."
                }
            } catch let error as StudyAchievementCatalogError {
                print("Achievement progress response failed validation: \(error)")
                loadedProgressError = "Your badges couldn’t be refreshed right now."
            } catch {
                // Preserve a same-revision snapshot when possible. Otherwise the catalog's
                // locked no-data selection remains a useful default while progress is offline.
                loadedProgressError = "Your badges couldn’t be refreshed right now."
            }
            guard !Task.isCancelled,
                  activeUserID == requestedUserID,
                  refreshSequence == sequence
            else { return }
            let catalogChanged = catalog?.revision != validatedCatalog.revision
            catalog = validatedCatalog
            catalogRefreshedAt = loadedCatalogRefreshedAt
            progress = loadedProgress
            if loadedProgressError == nil, loadedProgress != nil {
                progressRefreshedAt = .now
                if evaluate {
                    evaluatedAt = .now
                }
            }
            errorMessage = nil
            progressErrorMessage = loadedProgressError
            if catalogChanged {
                restoreCachedAssetURLs(for: validatedCatalog)
            }
            persist()

            startAssetPreparation(for: validatedCatalog)
        } catch {
            guard !Task.isCancelled,
                  activeUserID == requestedUserID,
                  refreshSequence == sequence
            else { return }
            errorMessage = "Achievements couldn’t be loaded right now."
        }
    }

    func imageURL(for achievement: PresentedStudyAchievement) -> URL? {
        guard let path = achievement.imageAsset?.path else { return nil }
        return cachedAssetURLs[path]
    }

    func isPreparingImage(for achievement: PresentedStudyAchievement) -> Bool {
        guard let path = achievement.imageAsset?.path else { return false }
        return preparingAssetPaths.contains(path)
    }

    func waitForAssetPreparation() async {
        while let assetPreparationTask {
            await assetPreparationTask.value
        }
    }

    func downloadedMediaWasCleared() {
        cancelAssetPreparation()
        cachedAssetURLs = [:]
        preparingAssetPaths = []
        guard let catalog else { return }
        startAssetPreparation(for: catalog)
    }

    func deleteLocalData(userID: Int) {
        defaults?.removeObject(forKey: persistenceKey(userID: userID))
        defaults?.removeObject(forKey: sessionKey(userID: userID))
        defaults?.removeObject(forKey: "study-milestones-v1-\(userID)")
        guard activeUserID == userID else { return }
        refreshSequence += 1
        cancelAssetPreparation()
        sessionState = SessionPersistedState()
        catalog = nil
        progress = nil
        catalogRefreshedAt = nil
        progressRefreshedAt = nil
        evaluatedAt = nil
        cachedAssetURLs = [:]
        preparingAssetPaths = []
    }

    @discardableResult
    private func startAssetPreparation(
        for catalog: StudyAchievementCatalog
    ) -> Task<Void, Never>? {
        guard mediaCache != nil, let userID = activeUserID else { return nil }
        if assetPreparationRevision == catalog.revision,
           let assetPreparationTask {
            return assetPreparationTask
        }
        restoreCachedAssetURLs(for: catalog)
        let missingPaths = Set(catalog.offlineImageAssets.map(\.path))
            .subtracting(cachedAssetURLs.keys)
        guard !missingPaths.isEmpty else {
            cancelAssetPreparation()
            preparingAssetPaths = []
            return nil
        }
        cancelAssetPreparation()
        assetPreparationSequence += 1
        let sequence = assetPreparationSequence
        assetPreparationRevision = catalog.revision
        preparingAssetPaths = missingPaths
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAssets(
                for: catalog,
                userID: userID,
                sequence: sequence
            )
        }
        assetPreparationTask = task
        return task
    }

    private func prepareAssets(
        for catalog: StudyAchievementCatalog,
        userID: Int,
        sequence: Int
    ) async {
        guard let mediaCache else { return }
        let featuredAssets = (earnedAchievements + inProgressAchievements)
            .compactMap(\.imageAsset)
        var seenPaths = Set<String>()
        let assets = (featuredAssets + catalog.offlineImageAssets)
            .filter { seenPaths.insert($0.path).inserted }

        for asset in assets {
            guard !Task.isCancelled,
                  activeUserID == userID,
                  assetPreparationSequence == sequence
            else { return }
            guard let remoteURL = api.sameOriginResourceURL(asset.path) else {
                preparingAssetPaths.remove(asset.path)
                continue
            }
            let localURL: URL?
            if let cachedURL = mediaCache.localURL(for: remoteURL) {
                localURL = cachedURL
            } else {
                localURL = try? await mediaCache.download(
                    remoteURL,
                    category: Self.mediaCategory
                )
            }
            guard !Task.isCancelled,
                  activeUserID == userID,
                  assetPreparationSequence == sequence
            else { return }
            if let localURL {
                cachedAssetURLs[asset.path] = localURL
            }
            preparingAssetPaths.remove(asset.path)
        }

        guard activeUserID == userID,
              assetPreparationSequence == sequence
        else { return }
        assetPreparationTask = nil
        assetPreparationRevision = nil
    }

    private func restorePersistedState(userID: Int) {
        catalog = nil
        progress = nil
        catalogRefreshedAt = nil
        progressRefreshedAt = nil
        evaluatedAt = nil
        cachedAssetURLs = [:]
        preparingAssetPaths = []

        guard let defaults,
              let data = defaults.data(forKey: persistenceKey(userID: userID)),
              let state = try? JSONDecoder().decode(CatalogPersistedState.self, from: data),
              let catalog = try? state.catalog.validated()
        else { return }
        let progress = try? state.progress?.validated()
        self.catalog = catalog
        self.progress = progress?.revision == catalog.revision ? progress : nil
        catalogRefreshedAt = state.catalogRefreshedAt
        progressRefreshedAt = state.progressRefreshedAt
        evaluatedAt = state.evaluatedAt
        restoreCachedAssetURLs(for: catalog)
    }

    private func restoreCachedAssetURLs(for catalog: StudyAchievementCatalog) {
        guard let mediaCache else {
            cachedAssetURLs = [:]
            return
        }
        cachedAssetURLs = Dictionary(
            uniqueKeysWithValues: catalog.offlineImageAssets.compactMap { asset in
                guard let remoteURL = api.sameOriginResourceURL(asset.path),
                      let localURL = mediaCache.localURL(for: remoteURL)
                else { return nil }
                return (asset.path, localURL)
            }
        )
    }

    private func persist() {
        guard let defaults,
              let activeUserID,
              let catalog,
              let catalogRefreshedAt,
              let data = try? JSONEncoder().encode(CatalogPersistedState(
                  catalog: catalog,
                  progress: progress,
                  catalogRefreshedAt: catalogRefreshedAt,
                  progressRefreshedAt: progressRefreshedAt,
                  evaluatedAt: evaluatedAt
              ))
        else { return }
        defaults.set(data, forKey: persistenceKey(userID: activeUserID))
    }

    private func persistenceKey(userID: Int) -> String {
        "\(persistenceKeyPrefix)-\(userID)"
    }

    private func cancelAssetPreparation() {
        assetPreparationSequence += 1
        assetPreparationTask?.cancel()
        assetPreparationTask = nil
        assetPreparationRevision = nil
    }

    func achievement(id: String) -> PresentedStudyAchievement? {
        guard let catalog else { return nil }
        return StudyAchievementPresentationModel.all(catalog: catalog, progress: progress)
            .first { $0.id == id && $0.isEarned }
    }

    func beginReviewSession() {
        guard activeUserID != nil else { return }
        if sessionState.activeSession?.isReadyForPresentation == true { return }
        sessionState.activeSession = ReviewSession(
            id: UUID(),
            records: [],
            baselineAwardIDs: progress?.awards.map(\.id),
            newAwardIDs: [],
            isReadyForPresentation: false,
            celebrationPresented: false
        )
        persistSessionState()
    }

    func recordReview(_ record: StudySessionReviewRecord) {
        guard var session = sessionState.activeSession,
              !session.isReadyForPresentation
        else { return }
        session.records.removeAll { $0.id == record.id }
        session.records.append(record)
        sessionState.activeSession = session
        persistSessionState()
    }

    func refreshCurrentSessionBaseline() {
        guard var session = sessionState.activeSession,
              !session.isReadyForPresentation
                || (!session.celebrationPresented && session.newAwardIDs.isEmpty),
              let progress
        else { return }
        let baseline = Set(session.baselineAwardIDs ?? [])
            .union(progress.awards.map(\.id))
        session.baselineAwardIDs = Array(baseline)
        session.newAwardIDs.removeAll { baseline.contains($0) }
        sessionState.activeSession = session
        persistSessionState()
    }

    func undoReview(eventID: String) {
        guard var session = sessionState.activeSession,
              !session.isReadyForPresentation
        else { return }
        session.records.removeAll { $0.id == eventID }
        sessionState.activeSession = session
        persistSessionState()
    }

    func prepareCurrentSessionCompletion() -> StudyAchievementCompletion? {
        prepareCompletion(requireNewAward: false)
    }

    func prepareInterruptedCompletion() -> StudyAchievementCompletion? {
        prepareCompletion(requireNewAward: true)
    }

    func markCelebrationPresented(sessionID: UUID) {
        guard var session = sessionState.activeSession, session.id == sessionID else { return }
        session.celebrationPresented = true
        sessionState.activeSession = session
        persistSessionState()
    }

    func consumeCompletion(sessionID: UUID) {
        guard sessionState.activeSession?.id == sessionID else { return }
        sessionState.activeSession = nil
        persistSessionState()
    }

    func cancelCurrentSession() {
        guard sessionState.activeSession?.isReadyForPresentation != true else { return }
        sessionState.activeSession = nil
        persistSessionState()
    }

    private func prepareCompletion(requireNewAward: Bool) -> StudyAchievementCompletion? {
        guard var session = sessionState.activeSession, !session.records.isEmpty else { return nil }
        if !session.isReadyForPresentation || !session.celebrationPresented || progress != nil {
            if let progress {
                let earnedIDs = Set(progress.awards.map(\.id))
                let detected: [StudyAchievementAward]
                if let baselineAwardIDs = session.baselineAwardIDs {
                    let baseline = Set(baselineAwardIDs)
                    detected = progress.awards.filter { !baseline.contains($0.id) }
                } else if let firstReviewAt = session.records.map(\.reviewedAt).min() {
                    // When the opening refresh failed, award timestamps prevent a later
                    // successful refresh from replaying the user's entire badge history.
                    detected = progress.awards.filter { $0.earnedAt >= firstReviewAt }
                } else {
                    detected = []
                }
                let detectedIDs = detected
                    .sorted { $0.earnedAt < $1.earnedAt }
                    .map(\.id)
                let dates = Dictionary(uniqueKeysWithValues: progress.awards.map {
                    ($0.id, $0.earnedAt)
                })
                let retainedIDs = session.newAwardIDs.filter { earnedIDs.contains($0) }
                let retainedIDSet = Set(retainedIDs)
                let appendedIDs = detectedIDs
                    .filter { !retainedIDSet.contains($0) }
                    .sorted {
                        dates[$0, default: .distantPast] < dates[$1, default: .distantPast]
                    }
                session.newAwardIDs = retainedIDs + appendedIDs
                if !appendedIDs.isEmpty {
                    // A completed optimistic carousel must reopen only for awards
                    // discovered by the authoritative evaluation.
                    session.celebrationPresented = false
                }
            } else if requireNewAward {
                return nil
            }
            guard !requireNewAward || !session.newAwardIDs.isEmpty else {
                sessionState.activeSession = session
                persistSessionState()
                return nil
            }
            session.isReadyForPresentation = true
        }
        sessionState.activeSession = session
        persistSessionState()
        return StudyAchievementCompletion(
            id: session.id,
            records: session.records,
            newAwardIDs: session.newAwardIDs,
            celebrationPresented: session.celebrationPresented
        )
    }

    private func loadSessionState(userID: Int) -> SessionPersistedState {
        guard let defaults,
              let data = defaults.data(forKey: sessionKey(userID: userID))
        else {
            return SessionPersistedState()
        }
        return (try? decoder.decode(SessionPersistedState.self, from: data))
            ?? SessionPersistedState()
    }

    private func persistSessionState() {
        guard let defaults,
              let activeUserID,
              let data = try? encoder.encode(sessionState)
        else { return }
        defaults.set(data, forKey: sessionKey(userID: activeUserID))
    }

    private func sessionKey(userID: Int) -> String {
        "\(sessionKeyPrefix)-\(userID)"
    }
}

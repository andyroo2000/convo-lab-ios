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
    private let api: APIClient
    private var activeUserID: Int?
    private var refreshedAt: Date?
    private var refreshSequence = 0

    private(set) var catalog: StudyAchievementCatalog?
    private(set) var progress: StudyAchievementProgress?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var progressErrorMessage: String?

    init(api: APIClient) {
        self.api = api
    }

    var recentAchievements: [PresentedStudyAchievement] {
        guard let catalog else { return [] }
        return StudyAchievementPresentationModel.recentEarned(catalog: catalog, progress: progress)
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
        activeUserID = userID
        progress = nil
        refreshedAt = nil
        errorMessage = nil
        progressErrorMessage = nil
        isLoading = false
    }

    func deactivate() {
        refreshSequence += 1
        activeUserID = nil
        progress = nil
        refreshedAt = nil
        errorMessage = nil
        progressErrorMessage = nil
        isLoading = false
    }

    func refreshIfNeeded(maxAge: TimeInterval = 60) async {
        if let refreshedAt, Date.now.timeIntervalSince(refreshedAt) < maxAge {
            return
        }
        await performRefresh()
    }

    func refresh() async {
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
        await performRefresh()
    }

    private func performRefresh() async {
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
            let loadedCatalog: StudyAchievementCatalog = try await api.request(
                "/api/achievements/catalog"
            )
            let validatedCatalog = try loadedCatalog.validated()
            var loadedProgress = progress?.revision == validatedCatalog.revision ? progress : nil
            var loadedProgressError: String?
            do {
                let response: StudyAchievementProgress = try await api.request(
                    "/api/achievements/evaluate",
                    method: "POST"
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
            catalog = validatedCatalog
            progress = loadedProgress
            refreshedAt = .now
            errorMessage = nil
            progressErrorMessage = loadedProgressError
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
        return api.sameOriginResourceURL(path)
    }
}

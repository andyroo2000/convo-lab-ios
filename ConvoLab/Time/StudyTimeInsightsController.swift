import Foundation

@MainActor
@Observable
final class StudyTimeInsightsController {
    struct RefreshRequest {
        let userID: Int
        let generation: Int
        let anchorDate: Date
    }

    struct RefreshResult {
        let loaded: Bool
        let failureMessage: String?
    }

    private let api: APIClient
    private let weeklyRecapService: any WeeklyStudyRecapServing
    private let snapshotCache: any StudyTimeSnapshotCaching
    private let now: () -> Date

    private(set) var analytics: StudyTimeAnalytics?
    private(set) var analyticsCache: [String: StudyTimeAnalytics] = [:]
    private(set) var analyticsCacheGeneration = 0
    private(set) var weeklyRecap: WeeklyStudyRecap?
    private(set) var weeklyRecapIsLoading = false
    private(set) var weeklyRecapErrorMessage: String?

    private var activeUserID: Int?
    private var analyticsRequestGeneration = 0
    private var weeklyRecapRequestGeneration = 0
    private var weeklyRecapRefreshedAt: Date?
    private var requestedAnalyticsAnchor: Date?

    init(
        api: APIClient,
        weeklyRecapService: (any WeeklyStudyRecapServing)? = nil,
        snapshotCache: (any StudyTimeSnapshotCaching)? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.api = api
        self.weeklyRecapService = weeklyRecapService ?? LiveWeeklyStudyRecapService(api: api)
        self.snapshotCache = snapshotCache ?? UserDefaultsStudyTimeSnapshotCache()
        self.now = now
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        analyticsRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        analytics = nil
        invalidateAnalyticsCache()
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
        activeUserID = userID
        restoreSnapshot(userID: userID)
    }

    func deactivate() {
        analyticsRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        activeUserID = nil
        analytics = nil
        invalidateAnalyticsCache()
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
    }

    func deleteLocalData(userID: Int) {
        snapshotCache.remove(userID: userID)
        guard activeUserID == userID else { return }
        analyticsRequestGeneration += 1
        analytics = nil
        invalidateAnalyticsCache()
    }

    func loadWeeklyRecap(
        timeZone: String = TimeZone.autoupdatingCurrent.identifier,
        force: Bool = false
    ) async {
        guard let requestedUserID = activeUserID, !weeklyRecapIsLoading else { return }
        if !force, let weeklyRecapRefreshedAt {
            let age = now().timeIntervalSince(weeklyRecapRefreshedAt)
            if age >= 0, age < 15 * 60 { return }
        }
        weeklyRecapRequestGeneration += 1
        let generation = weeklyRecapRequestGeneration
        weeklyRecapIsLoading = true
        weeklyRecapErrorMessage = nil
        defer {
            if activeUserID == requestedUserID, weeklyRecapRequestGeneration == generation {
                weeklyRecapIsLoading = false
            }
        }
        do {
            let value = try await weeklyRecapService.recap(timeZone: timeZone, weekStartsOn: 2)
            guard activeUserID == requestedUserID,
                  weeklyRecapRequestGeneration == generation
            else { return }
            weeklyRecap = value
            weeklyRecapRefreshedAt = now()
            persistSnapshot(timeZone: timeZone)
        } catch {
            guard activeUserID == requestedUserID,
                  weeklyRecapRequestGeneration == generation
            else { return }
            weeklyRecapErrorMessage = "Couldn’t load your weekly recap. Pull to refresh and try again."
        }
    }

    @discardableResult
    func loadAnalytics(anchorDate: Date) async -> RefreshResult {
        let result = await refreshAnalytics(anchorDate: anchorDate)
        if result.loaded {
            let confirmedAnchor = analytics
                .flatMap { analyticsAnchorDate(from: $0.anchorDate) }
                ?? anchorDate
            requestedAnalyticsAnchor = Calendar.current.isDateInToday(confirmedAnchor)
                ? nil
                : confirmedAnchor
        }
        return result
    }

    func cachedAnalytics(anchorDate: Date) -> StudyTimeAnalytics? {
        analyticsCache[analyticsAnchorString(from: anchorDate)]
    }

    @discardableResult
    func prefetchAnalytics(anchorDate: Date) async -> RefreshResult {
        let key = analyticsAnchorString(from: anchorDate)
        if analyticsCache[key] != nil {
            return RefreshResult(loaded: true, failureMessage: nil)
        }
        guard let userID = activeUserID else {
            return RefreshResult(loaded: false, failureMessage: nil)
        }
        let cacheGeneration = analyticsCacheGeneration
        do {
            let fetchedAnalytics = try await fetchAnalytics(anchorDate: anchorDate)
            guard activeUserID == userID,
                  analyticsCacheGeneration == cacheGeneration
            else {
                return RefreshResult(loaded: false, failureMessage: nil)
            }
            analyticsCache[key] = fetchedAnalytics
            analyticsCache[fetchedAnalytics.anchorDate] = fetchedAnalytics
            return RefreshResult(loaded: true, failureMessage: nil)
        } catch {
            guard activeUserID == userID,
                  analyticsCacheGeneration == cacheGeneration
            else {
                return RefreshResult(loaded: false, failureMessage: nil)
            }
            return RefreshResult(loaded: false, failureMessage: error.localizedDescription)
        }
    }

    @discardableResult
    func selectCachedAnalytics(anchorDate: Date) -> Bool {
        let key = analyticsAnchorString(from: anchorDate)
        guard let cached = analyticsCache[key] else { return false }
        analyticsRequestGeneration += 1
        analytics = cached
        let confirmedAnchor = analyticsAnchorDate(from: cached.anchorDate) ?? anchorDate
        requestedAnalyticsAnchor = Calendar.current.isDateInToday(confirmedAnchor)
            ? nil
            : confirmedAnchor
        return true
    }

    func prepareRefresh(anchorDate: Date? = nil) -> RefreshRequest? {
        guard let userID = activeUserID else { return nil }
        let effectiveAnchor = anchorDate ?? requestedAnalyticsAnchor ?? .now
        invalidateAnalyticsCache()
        analyticsRequestGeneration += 1
        return RefreshRequest(
            userID: userID,
            generation: analyticsRequestGeneration,
            anchorDate: effectiveAnchor
        )
    }

    func finishRefresh(_ request: RefreshRequest) async -> RefreshResult {
        do {
            let fetchedAnalytics = try await fetchAnalytics(anchorDate: request.anchorDate)
            guard isCurrent(request) else {
                return RefreshResult(loaded: false, failureMessage: nil)
            }
            analytics = fetchedAnalytics
            analyticsCache[analyticsAnchorString(from: request.anchorDate)] = fetchedAnalytics
            analyticsCache[fetchedAnalytics.anchorDate] = fetchedAnalytics
            persistSnapshot()
            return RefreshResult(loaded: true, failureMessage: nil)
        } catch {
            guard isCurrent(request) else {
                return RefreshResult(loaded: false, failureMessage: nil)
            }
            return RefreshResult(loaded: false, failureMessage: error.localizedDescription)
        }
    }

    func refreshAnalytics(anchorDate: Date? = nil) async -> RefreshResult {
        guard let request = prepareRefresh(anchorDate: anchorDate) else {
            return RefreshResult(loaded: false, failureMessage: nil)
        }
        return await finishRefresh(request)
    }

    private func isCurrent(_ request: RefreshRequest) -> Bool {
        activeUserID == request.userID && analyticsRequestGeneration == request.generation
    }

    private func fetchAnalytics(anchorDate: Date) async throws -> StudyTimeAnalytics {
        try await api.request(
            "/api/study/activity-analytics",
            query: [
                URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
                URLQueryItem(name: "weekStartsOn", value: "2"),
                URLQueryItem(name: "anchorDate", value: analyticsAnchorString(from: anchorDate)),
            ],
            response: StudyTimeAnalytics.self
        )
    }

    private func analyticsAnchorString(from anchorDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: anchorDate)
    }

    private func analyticsAnchorDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func invalidateAnalyticsCache() {
        analyticsCache = [:]
        analyticsCacheGeneration += 1
    }

    private func restoreSnapshot(userID: Int) {
        let timeZone = TimeZone.autoupdatingCurrent.identifier
        guard let snapshot = snapshotCache.load(userID: userID, timeZone: timeZone) else { return }
        let age = now().timeIntervalSince(snapshot.savedAt)
        guard age >= 0, age < 7 * 86_400 else { return }
        if let cachedAnalytics = snapshot.analytics,
           cachedAnalytics.anchorDate == analyticsAnchorString(from: now())
        {
            analytics = cachedAnalytics
            analyticsCache[cachedAnalytics.anchorDate] = cachedAnalytics
        }
        if let cachedRecap = snapshot.weeklyRecap,
           recapMatchesMostRecentCompletedWeek(cachedRecap, timeZone: timeZone)
        {
            weeklyRecap = cachedRecap
            weeklyRecapRefreshedAt = snapshot.weeklyRecapRefreshedAt ?? snapshot.savedAt
        }
    }

    private func persistSnapshot(
        timeZone: String = TimeZone.autoupdatingCurrent.identifier
    ) {
        guard let userID = activeUserID else { return }
        snapshotCache.save(
            StudyTimeSnapshot(
                savedAt: now(),
                analytics: analytics,
                weeklyRecap: weeklyRecap,
                weeklyRecapRefreshedAt: weeklyRecapRefreshedAt
            ),
            userID: userID,
            timeZone: timeZone
        )
    }

    private func recapMatchesMostRecentCompletedWeek(
        _ recap: WeeklyStudyRecap,
        timeZone identifier: String
    ) -> Bool {
        guard let timeZone = TimeZone(identifier: identifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        guard let currentWeekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: now()
        )?.start else { return false }
        return abs(recap.week.endsAt.timeIntervalSince(currentWeekStart)) < 1
    }
}

import Foundation

nonisolated enum StudyTodayPresentation {
    private static let reviewEstimateSecondsPerCard = 23.0

    static func estimatedReviewMinutes(reviewCount: Int) -> Int? {
        guard reviewCount > 0 else { return nil }

        return max(1, Int(ceil(Double(reviewCount) * reviewEstimateSecondsPerCard / 60)))
    }

    static func reviewTimeText(reviewCount: Int) -> String {
        guard reviewCount > 0 else { return "All caught up" }
        guard let minutes = estimatedReviewMinutes(reviewCount: reviewCount) else {
            return "All caught up"
        }
        return "About \(minutes) min"
    }

    static func reviewCountText(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "review" : "reviews")"
    }

    static func newCardCountText(_ count: Int) -> String {
        "\(count.formatted()) new \(count == 1 ? "card" : "cards")"
    }

    static func shouldRefreshWaniKani(
        reviewCountUpdatedAt: Date?,
        relativeTo now: Date = .now,
        maxAge: TimeInterval = 15 * 60
    ) -> Bool {
        guard let reviewCountUpdatedAt else { return true }
        return now.timeIntervalSince(reviewCountUpdatedAt) >= maxAge
    }

    static func shouldRefreshCalendar(
        statusFetchedAt: Date?,
        relativeTo now: Date = .now,
        maxAge: TimeInterval = 15 * 60
    ) -> Bool {
        guard let statusFetchedAt else { return true }
        return now.timeIntervalSince(statusFetchedAt) >= maxAge
    }

    static func lessonTiming(
        _ startsAt: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfEventDay = calendar.startOfDay(for: startsAt)
        let dayOffset = calendar.dateComponents(
            [.day],
            from: startOfToday,
            to: startOfEventDay
        ).day
        let day: String

        switch dayOffset {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        default:
            day = startsAt.formatted(
                .dateTime.month(.abbreviated).day().locale(locale)
            )
        }

        let time = startsAt.formatted(.dateTime.hour().minute().locale(locale))
        return "\(day), \(time)"
    }
}

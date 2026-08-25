import Foundation

nonisolated enum StudyTodayPresentation {
    static func estimatedReviewMinutes(
        reviewCount: Int,
        medianReviewDurationSeconds: Double?
    ) -> Int? {
        guard reviewCount > 0,
              let medianReviewDurationSeconds,
              medianReviewDurationSeconds.isFinite,
              medianReviewDurationSeconds > 0
        else { return nil }

        return max(1, Int(ceil(Double(reviewCount) * medianReviewDurationSeconds / 60)))
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

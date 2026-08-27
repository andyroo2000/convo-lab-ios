import Foundation

nonisolated enum StudyTodayPresentation {
    struct LessonTiming: Equatable, Sendable {
        let weekday: String
        let date: String
        let time: String
    }

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
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> LessonTiming {
        LessonTiming(
            weekday: format(
                startsAt,
                template: "EEE",
                calendar: calendar,
                locale: locale
            ),
            date: format(
                startsAt,
                template: "MMM d",
                calendar: calendar,
                locale: locale
            ),
            time: format(
                startsAt,
                template: "j:mm",
                calendar: calendar,
                locale: locale
            )
        )
    }

    private static func format(
        _ date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

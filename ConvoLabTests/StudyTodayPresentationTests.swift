import Foundation
import Testing
@testable import ConvoLab

struct StudyTodayPresentationTests {
    @Test func estimatesReviewMinutesByRoundingUp() {
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(reviewCount: 14) == 6
        )
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(reviewCount: 74) == 29
        )
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(reviewCount: 0) == nil
        )
    }

    @Test func distinguishesCaughtUpReviewsFromAnEstimate() {
        #expect(
            StudyTodayPresentation.reviewTimeText(reviewCount: 0) == "All caught up"
        )
        #expect(
            StudyTodayPresentation.reviewTimeText(reviewCount: 14) == "About 6 min"
        )
    }

    @Test func formatsSingularAndPluralCounts() {
        #expect(StudyTodayPresentation.reviewCountText(1) == "1 review")
        #expect(StudyTodayPresentation.reviewCountText(14) == "14 reviews")
        #expect(StudyTodayPresentation.newCardCountText(1) == "1 new card")
        #expect(StudyTodayPresentation.newCardCountText(5) == "5 new cards")
    }

    @Test func refreshesWaniKaniWhenTheReviewCountIsStaleOrMissing() {
        let now = Date(timeIntervalSince1970: 1_787_584_400)

        #expect(
            StudyTodayPresentation.shouldRefreshWaniKani(
                reviewCountUpdatedAt: nil,
                relativeTo: now
            )
        )
        #expect(
            !StudyTodayPresentation.shouldRefreshWaniKani(
                reviewCountUpdatedAt: now.addingTimeInterval(-14 * 60),
                relativeTo: now
            )
        )
        #expect(
            StudyTodayPresentation.shouldRefreshWaniKani(
                reviewCountUpdatedAt: now.addingTimeInterval(-15 * 60),
                relativeTo: now
            )
        )
    }

    @Test func refreshesCalendarStatusWhenItIsStaleOrMissing() {
        let now = Date(timeIntervalSince1970: 1_787_584_400)

        #expect(
            StudyTodayPresentation.shouldRefreshCalendar(
                statusFetchedAt: nil,
                relativeTo: now
            )
        )
        #expect(
            !StudyTodayPresentation.shouldRefreshCalendar(
                statusFetchedAt: now.addingTimeInterval(-14 * 60),
                relativeTo: now
            )
        )
        #expect(
            StudyTodayPresentation.shouldRefreshCalendar(
                statusFetchedAt: now.addingTimeInterval(-15 * 60),
                relativeTo: now
            )
        )
    }

    @Test func formatsLessonWeekdayDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let startsAt = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2027,
            month: 8,
            day: 31,
            hour: 14,
            minute: 30
        ).date!

        let timing = StudyTodayPresentation.lessonTiming(
            startsAt,
            calendar: calendar,
            locale: locale
        )

        #expect(timing.weekday == "Tue")
        #expect(timing.date == "Aug 31")
        #expect(timing.time.contains("2:30"))
        #expect(timing.time.hasSuffix("PM"))
    }
}

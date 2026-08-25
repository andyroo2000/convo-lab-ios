import Foundation
import Testing
@testable import ConvoLab

struct StudyTodayPresentationTests {
    @Test func estimatesReviewMinutesByRoundingUp() {
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(
                reviewCount: 14,
                medianReviewDurationSeconds: 25
            ) == 6
        )
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(
                reviewCount: 14,
                medianReviewDurationSeconds: nil
            ) == nil
        )
        #expect(
            StudyTodayPresentation.estimatedReviewMinutes(
                reviewCount: 0,
                medianReviewDurationSeconds: 25
            ) == nil
        )
    }

    @Test func distinguishesCaughtUpReviewsFromACalibratingEstimate() {
        #expect(
            StudyTodayPresentation.reviewTimeText(
                reviewCount: 0,
                medianReviewDurationSeconds: nil
            ) == "All caught up"
        )
        #expect(
            StudyTodayPresentation.reviewTimeText(
                reviewCount: 14,
                medianReviewDurationSeconds: nil
            ) == "Time estimate is calibrating"
        )
        #expect(
            StudyTodayPresentation.reviewTimeText(
                reviewCount: 14,
                medianReviewDurationSeconds: 25
            ) == "About 6 min"
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

    @Test func describesTodayAndTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_787_584_400)
        let laterToday = now.addingTimeInterval(60 * 60)
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)

        #expect(
            StudyTodayPresentation.lessonTiming(
                laterToday,
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ).hasPrefix("Today, ")
        )
        #expect(
            StudyTodayPresentation.lessonTiming(
                tomorrow,
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ).hasPrefix("Tomorrow, ")
        )
    }
}

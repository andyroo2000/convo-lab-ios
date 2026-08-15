import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeAnalyticsProjectionTests: XCTestCase {
    func testCategorySelectionControlsTotalsBucketsAndBest() throws {
        let range = makeRange(
            key: .week,
            startsAt: date("2026-08-10T04:00:00Z"),
            endsAt: date("2026-08-17T04:00:00Z"),
            categories: [.review: 3_600_000, .listen: 2_400_000, .conversation: 1_800_000],
            buckets: [
                makeBucket(
                    start: "2026-08-10T04:00:00Z",
                    end: "2026-08-11T04:00:00Z",
                    categories: [.review: 600_000, .listen: 2_400_000]
                ),
                makeBucket(
                    start: "2026-08-11T04:00:00Z",
                    end: "2026-08-12T04:00:00Z",
                    categories: [.review: 3_000_000, .conversation: 1_800_000]
                ),
            ]
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: date("2026-08-12T16:00:00Z"),
            includedCategories: [.review, .conversation],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.includedCategoryList, [.review, .conversation])
        XCTAssertEqual(projection.totalDurationMs, 5_400_000)
        XCTAssertEqual(projection.elapsedDayCount, 3)
        XCTAssertEqual(projection.dailyAverageDurationMs, 1_800_000)
        XCTAssertEqual(projection.bestBucket?.startsAt, date("2026-08-11T04:00:00Z"))
        XCTAssertEqual(projection.bestBucketDurationMs, 4_800_000)
        XCTAssertEqual(projection.duration(for: .listen), 2_400_000)
    }

    func testCompletedFixedPeriodDoesNotCountExclusiveEndBoundary() {
        let range = makeRange(
            key: .week,
            startsAt: date("2026-08-10T04:00:00Z"),
            endsAt: date("2026-08-17T04:00:00Z"),
            categories: [.review: 7_000],
            buckets: []
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: date("2026-08-20T12:00:00Z"),
            includedCategories: [.review],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.elapsedDayCount, 7)
        XCTAssertEqual(projection.dailyAverageDurationMs, 1_000)
    }

    func testElapsedDaysFollowCalendarAcrossDaylightSavingTransition() {
        let range = makeRange(
            key: .week,
            startsAt: date("2026-03-07T05:00:00Z"),
            endsAt: date("2026-03-14T04:00:00Z"),
            categories: [.review: 700],
            buckets: []
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: date("2026-03-15T12:00:00Z"),
            includedCategories: [.review],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.elapsedDayCount, 7)
    }

    func testCurrentPeriodUsesElapsedDaysButDomainIncludesFutureDays() {
        let start = date("2026-08-10T04:00:00Z")
        let end = date("2026-08-17T04:00:00Z")
        let range = makeRange(
            key: .week,
            startsAt: start,
            endsAt: end,
            categories: [.review: 3_000],
            buckets: []
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: date("2026-08-12T16:00:00Z"),
            includedCategories: [.review],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.elapsedDayCount, 3)
        XCTAssertEqual(projection.dailyAverageDurationMs, 1_000)
        XCTAssertEqual(projection.chartDomain, start...end)
    }

    func testAllTimeIncludesTheEffectiveEndDay() {
        let end = date("2026-08-12T16:00:00Z")
        let range = makeRange(
            key: .all,
            startsAt: date("2026-08-10T04:00:00Z"),
            endsAt: end,
            categories: [.review: 3_000],
            buckets: []
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: end,
            includedCategories: [.review],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.elapsedDayCount, 3)
        XCTAssertEqual(projection.dailyAverageDurationMs, 1_000)
    }

    func testEmptySelectionHasSafeZeroSummary() {
        let range = makeRange(
            key: .today,
            startsAt: date("2026-08-15T04:00:00Z"),
            endsAt: date("2026-08-16T04:00:00Z"),
            categories: [.review: 3_600_000],
            buckets: []
        )
        let projection = StudyTimeAnalyticsProjection(
            analytics: range,
            generatedAt: date("2026-08-15T16:00:00Z"),
            includedCategories: [],
            calendar: newYorkCalendar
        )

        XCTAssertEqual(projection.totalDurationMs, 0)
        XCTAssertEqual(projection.dailyAverageDurationMs, 0)
        XCTAssertNil(projection.bestBucket)
        XCTAssertEqual(projection.bestBucketDurationMs, 0)
    }

    private var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func makeRange(
        key: StudyTimeRange,
        startsAt: Date,
        endsAt: Date,
        categories: [StudyActivityCategory: Int],
        buckets: [StudyTimeAnalyticsBucket]
    ) -> StudyTimeAnalyticsRange {
        StudyTimeAnalyticsRange(
            key: key,
            startsAt: startsAt,
            endsAt: endsAt,
            totalMs: categories.values.reduce(0, +),
            categories: rawCategories(categories),
            buckets: buckets
        )
    }

    private func makeBucket(
        start: String,
        end: String,
        categories: [StudyActivityCategory: Int]
    ) -> StudyTimeAnalyticsBucket {
        StudyTimeAnalyticsBucket(
            startsAt: date(start),
            endsAt: date(end),
            totalMs: categories.values.reduce(0, +),
            categories: rawCategories(categories)
        )
    }

    private func rawCategories(
        _ categories: [StudyActivityCategory: Int]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) })
    }

    private func date(_ value: String) -> Date {
        try! Date(value, strategy: .iso8601)
    }
}

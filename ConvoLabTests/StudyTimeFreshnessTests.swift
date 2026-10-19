import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeFreshnessTests: XCTestCase {
    func testOpenAndClosedPeriodsHaveDifferentFreshnessWindows() throws {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        for (anchor, range, limit) in [("2026-10-18", StudyTimeRange.month, 120.0),
                                      ("2026-09-01", .month, 900.0)] {
            let response = fixture.response(anchor: fixture.date(anchor))
            let value = StudyTimeAnalytics(generatedAt: response.generatedAt, anchorDate: response.anchorDate,
                                           timezone: response.timezone, ranges: [try XCTUnwrap(response.range(range))])
            let entry = StudyTimePeriodCache.Entry(value: value, generation: 3, receivedAt: fixture.now)
            XCTAssertTrue(StudyTimePeriodFreshness.isFresh(entry, generation: 3,
                                                         now: fixture.now.addingTimeInterval(limit - 1), context: context))
            XCTAssertFalse(StudyTimePeriodFreshness.isFresh(entry, generation: 3,
                                                          now: fixture.now.addingTimeInterval(limit), context: context))
            XCTAssertFalse(StudyTimePeriodFreshness.isFresh(entry, generation: 4, now: fixture.now, context: context))
            XCTAssertFalse(StudyTimePeriodFreshness.isFresh(entry, generation: 3,
                                                          now: fixture.now.addingTimeInterval(-1), context: context))
        }
    }

    func testAllRemainsOpenEvenWhenItsEndEqualsGeneratedAt() throws {
        let fixture = StudyTimePeriodFixture()
        let source = try XCTUnwrap(fixture.response(anchor: fixture.now).range(.all))
        let all = StudyTimeAnalyticsRange(key: .all, startsAt: source.startsAt, endsAt: fixture.now,
                                          totalMs: source.totalMs, categories: source.categories, buckets: source.buckets)
        let value = StudyTimeAnalytics(generatedAt: fixture.now, anchorDate: fixture.anchor(fixture.now),
                                       timezone: fixture.calendar.timeZone.identifier, ranges: [all])
        let entry = StudyTimePeriodCache.Entry(value: value, generation: 1, receivedAt: fixture.now)
        XCTAssertFalse(StudyTimePeriodFreshness.isFresh(entry, generation: 1,
                                                      now: fixture.now.addingTimeInterval(121),
                                                      context: .init(timeZone: fixture.calendar.timeZone)))
    }

    func testMidnightExpiresOpenPeriodsWhileClosedWeeksRemainUsable() throws {
        let fixture = StudyTimePeriodFixture(now: "2026-10-19T03:59:30Z")
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        var cache = StudyTimePeriodCache()
        cache.insert(fixture.response(anchor: fixture.now), requestedAnchor: "2026-10-18", generation: 1,
                     receivedAt: fixture.now)
        for range in [StudyTimeRange.week, .month, .year, .all] {
            let entry = try XCTUnwrap(cache.entry(anchor: fixture.now, range: range, context: context))
            XCTAssertFalse(StudyTimePeriodFreshness.isFresh(entry, generation: 1,
                                                          now: fixture.now.addingTimeInterval(60), context: context))
        }
        let closed = try XCTUnwrap(cache.entry(anchor: fixture.date("2026-10-11"), range: .week, context: context))
        XCTAssertTrue(StudyTimePeriodFreshness.isFresh(closed, generation: 1,
                                                     now: fixture.now.addingTimeInterval(60), context: context))
    }

    func testBoundedHistoryDropsOldResponsesAndTheirCanonicalPeriods() throws {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        var cache = StudyTimePeriodCache()
        for month in 1...14 {
            let anchor = fixture.calendar.date(byAdding: .month, value: -month, to: fixture.now)!
            cache.insert(fixture.response(anchor: anchor), requestedAnchor: fixture.anchor(anchor), generation: 1)
        }
        XCTAssertEqual(cache.snapshots.count, 12)
        XCTAssertNil(cache.entry(anchor: fixture.date("2026-09-18"), range: .month, context: context))
        XCTAssertNotNil(cache.entry(anchor: fixture.date("2025-08-18"), range: .month, context: context))
    }
}

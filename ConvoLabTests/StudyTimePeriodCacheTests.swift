import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePeriodCacheTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testFreshCoveredWeekReplacesAnOlderDirectWeek() throws {
        let older = StudyTimePeriodFixture()
        let newer = StudyTimePeriodFixture(now: "2026-10-18T17:00:00Z")
        let context = StudyTimeAnalyticsCalendar(timeZone: newer.calendar.timeZone)
        for generation in [1, 2] {
            var cache = StudyTimePeriodCache()
            cache.insert(older.response(anchor: older.date("2026-10-11")),
                         requestedAnchor: "2026-10-11", generation: 1)
            cache.insert(newer.response(anchor: newer.now), requestedAnchor: "2026-10-18", generation: generation)
            let result = try XCTUnwrap(cache.entry(anchor: newer.date("2026-10-11"), range: .week, context: context))
            XCTAssertEqual(result.value.generatedAt, newer.now)
            XCTAssertEqual(result.generation, generation)
            XCTAssertEqual(result.value.range(.week), newer.response(anchor: newer.date("2026-10-11")).range(.week))
        }
    }

    func testMonthYearAndCoveredWeekNavigationReuseTheInitialResponse() async throws {
        let harness = StudyTimePeriodHarness()
        let fixture = harness.fixture
        let loaded = await harness.controller.loadAnalytics(anchorDate: fixture.now)
        XCTAssertTrue(loaded.loaded)
        for (anchor, range) in [("2026-10-01", StudyTimeRange.month), ("2026-01-01", .year),
                                ("2026-10-11", .week), ("2026-10-18", .week)] {
            let result = await harness.controller.loadAnalytics(anchorDate: fixture.date(anchor), range: range)
            XCTAssertTrue(result.loaded)
            XCTAssertEqual(harness.controller.analytics?.range(range), fixture.response(anchor: fixture.date(anchor)).range(range))
        }
        XCTAssertEqual(harness.requests.current, 1)
        XCTAssertNil(harness.controller.analytics?.range(.today), "A weekly projection must not invent hourly data")
        let day = await harness.controller.loadAnalytics(anchorDate: fixture.date("2026-10-11"), range: .today)
        XCTAssertTrue(day.loaded)
        XCTAssertNotNil(harness.controller.analytics?.range(.today))
        XCTAssertEqual(harness.requests.current, 2)
    }

    func testDerivedWeeksPreserveDSTBoundsCategoriesAndGenerationTime() throws {
        for (now, anchor) in [("2026-03-10T16:00:00Z", "2026-03-08"),
                              ("2026-11-10T16:00:00Z", "2026-11-01")] {
            let fixture = StudyTimePeriodFixture(now: now)
            let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone, weekStartsOn: 1)
            var cache = StudyTimePeriodCache()
            let response = fixture.response(anchor: fixture.now)
            cache.insert(response, requestedAnchor: response.anchorDate, generation: 4)
            let projected = try XCTUnwrap(cache.entry(anchor: fixture.date(anchor), range: .week, context: context))
            let week = try XCTUnwrap(projected.value.range(.week))
            XCTAssertEqual(week.buckets.count, 7)
            XCTAssertTrue(week.buckets.contains { $0.endsAt.timeIntervalSince($0.startsAt) != 86_400 })
            XCTAssertEqual(week.totalMs, week.categories.values.reduce(0, +))
            XCTAssertEqual(projected.value.generatedAt, fixture.now)
            XCTAssertEqual(projected.generation, 4)
            XCTAssertEqual(week.startsAt, context.bounds(.week, anchor: fixture.date(anchor))?.start)
            XCTAssertEqual(week.endsAt, context.bounds(.week, anchor: fixture.date(anchor))?.end)
        }
    }

    func testIncompleteOrCrossMonthCoverageIsNotInventedAsZeros() {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        var cache = StudyTimePeriodCache()
        let response = fixture.response(anchor: fixture.now)
        cache.insert(response, requestedAnchor: response.anchorDate, generation: 1)
        XCTAssertNil(cache.entry(anchor: fixture.date("2026-10-01"), range: .week, context: context))
        let month = response.range(.month)!
        let incomplete = StudyTimeAnalyticsRange(key: .month, startsAt: month.startsAt, endsAt: month.endsAt,
                                                 totalMs: month.totalMs, categories: month.categories,
                                                 buckets: Array(month.buckets.dropFirst(6)))
        cache = StudyTimePeriodCache()
        cache.insert(.init(generatedAt: fixture.now, anchorDate: response.anchorDate,
                           timezone: response.timezone, ranges: [incomplete]),
                     requestedAnchor: response.anchorDate, generation: 1)
        XCTAssertNil(cache.entry(anchor: fixture.date("2026-10-11"), range: .week, context: context))
    }

    func testNewerPeriodSnapshotWinsWhenDifferentAnchorsCompleteOutOfOrder() throws {
        let newer = StudyTimePeriodFixture(now: "2026-10-18T17:00:00Z")
        let older = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: newer.calendar.timeZone)
        var cache = StudyTimePeriodCache()
        cache.insert(newer.response(anchor: newer.now), requestedAnchor: "2026-10-18", generation: 1)
        cache.insert(older.response(anchor: older.date("2026-10-01")), requestedAnchor: "2026-10-01", generation: 1)
        let result = try XCTUnwrap(cache.entry(anchor: newer.now, range: .month, context: context))
        XCTAssertEqual(result.value.generatedAt, newer.now)
        XCTAssertNil(cache.entry(anchor: newer.now, range: .month,
                                 context: .init(timeZone: TimeZone(identifier: "Asia/Tokyo")!)))
    }
}

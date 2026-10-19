import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeScopedAnalyticsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testMonthCoverageSuppliesWeeksButNotHourlyOrFullResponses() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let fixture = StudyTimePeriodFixture()
        let controller = transport.makeController(now: { fixture.now })
        let month = Task { await controller.loadAnalytics(anchorDate: fixture.now, range: .month) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        XCTAssertEqual(ranges(in: transport.urls[0]), ["month"])
        try transport.complete(0)
        _ = await month.value
        let week = await controller.loadAnalytics(anchorDate: fixture.date("2026-10-11"), range: .week)
        XCTAssertTrue(week.loaded)
        XCTAssertEqual(transport.count, 1)
        XCTAssertNil(controller.cachedAnalytics(anchorDate: fixture.now, range: .today))
        XCTAssertNil(controller.cachedAnalytics(anchorDate: fixture.now))
        let hourly = Task { await controller.loadAnalytics(anchorDate: fixture.now, range: .today) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        XCTAssertEqual(ranges(in: transport.urls[1]), ["today"])
        try transport.complete(1)
        _ = await hourly.value
        XCTAssertNotNil(controller.cachedAnalytics(anchorDate: fixture.now, range: .month))
        XCTAssertNotNil(controller.cachedAnalytics(anchorDate: fixture.now, range: .today))
    }

    func testDisjointAndFullRequestsAtTheSameAnchorNeverJoinPartialTransport() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let fixture = StudyTimePeriodFixture()
        let controller = transport.makeController(now: { fixture.now })
        let week = Task { await controller.prefetchAnalytics(anchorDate: fixture.now, range: .week) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        let year = Task { await controller.prefetchAnalytics(anchorDate: fixture.now, range: .year) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        let full = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(3)], timeout: 2)
        XCTAssertEqual(ranges(in: transport.urls[0]), ["week", "month"])
        XCTAssertEqual(ranges(in: transport.urls[1]), ["year"])
        XCTAssertEqual(ranges(in: transport.urls[2]), [])
        for index in [2, 0, 1] { try transport.complete(index) }
        let results = await [week.value, year.value, full.value]
        XCTAssertTrue(results.allSatisfy(\.loaded))
        XCTAssertEqual(controller.cachedAnalytics(anchorDate: fixture.now)?.ranges.count, 5)
        XCTAssertEqual(controller.analytics?.ranges.count, 5)
        XCTAssertEqual(transport.count, 3)
    }

    func testDisjointScopedSnapshotsSurviveDiskRestoreWithoutInventingCoverage() async throws {
        let suite = "scoped-periods-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
        let warm = StudyTimePeriodHarness(snapshotCache: cache)
        for range in [StudyTimeRange.month, .year] {
            _ = await warm.controller.prefetchAnalytics(anchorDate: warm.fixture.now, range: range)
        }
        warm.controller.deactivate()
        let restored = StudyTimePeriodHarness(snapshotCache: cache)
        XCTAssertNotNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.now, range: .month))
        XCTAssertNotNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.now, range: .year))
        XCTAssertNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.now, range: .today))
        XCTAssertNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.now))
        let saved = try XCTUnwrap(cache.load(userID: 42, timeZone: "America/New_York")?.periodHistory)
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.snapshots.count, 2)
        XCTAssertTrue(restored.controller.selectCachedAnalytics(anchorDate: restored.fixture.now, range: .month))
        _ = await restored.controller.prefetchAnalytics(anchorDate: restored.fixture.now, range: .month)
        XCTAssertEqual(restored.requests.current, 1)
    }

    private func ranges(in url: URL) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            .filter { $0.name == "ranges[]" }.compactMap(\.value)
    }
}

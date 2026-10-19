import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePeriodRequestTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testRapidUncachedRangeChangesFallBackToTheLastAvailableChartWhenTheLatestFails() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let fixture = StudyTimePeriodFixture()
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.date("2026-09-11")) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        XCTAssertTrue(controller.selectCachedAnalytics(anchorDate: fixture.date("2026-09-11"), range: .week))
        let visible = controller.analytics
        let today = Task { await controller.loadAnalytics(anchorDate: fixture.now, range: .today) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        today.cancel()
        let fallback = StudyTimeRangeSelection.fallback(preferred: .today, analytics: controller.analytics)
        let month = Task { await controller.loadAnalytics(anchorDate: fixture.now, range: .month) }
        await fulfillment(of: [transport.expecting(3)], timeout: 2)
        try transport.complete(2, error: URLError(.notConnectedToInternet))
        let monthResult = await month.value
        XCTAssertFalse(monthResult.loaded)
        try transport.complete(1)
        _ = await today.value
        XCTAssertEqual(controller.analytics, visible)
        XCTAssertEqual(fallback, .week)
        XCTAssertNotNil(controller.analytics?.range(try XCTUnwrap(fallback)))
    }

    func testDeactivationRejectsCachedNavigationBeforePendingPushFinishes() async throws {
        let harness = StudyTimePeriodHarness()
        _ = await harness.controller.loadAnalytics(anchorDate: harness.fixture.now)
        let visible = harness.controller.analytics
        harness.controller.invalidateRequestsForDeactivation()
        XCTAssertFalse(harness.controller.selectCachedAnalytics(anchorDate: harness.fixture.date("2026-10-11"), range: .week))
        XCTAssertNil(harness.controller.cachedAnalytics(anchorDate: harness.fixture.now))
        XCTAssertEqual(harness.controller.analytics, visible)
        XCTAssertEqual(harness.requests.current, 1)
    }

    func testNavigationJoinsPrefetchAndCancellingOneConsumerPreservesTheOther() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let anchor = StudyTimePeriodFixture().date("2026-10-11")
        let prefetch = Task { await controller.prefetchAnalytics(anchorDate: anchor, range: .week) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        let joined = expectation(description: "Navigation joined")
        let navigation = Task {
            joined.fulfill()
            return await controller.loadAnalytics(anchorDate: anchor, range: .week)
        }
        await fulfillment(of: [joined], timeout: 2)
        prefetch.cancel()
        try transport.complete(0)
        let prefetchResult = await prefetch.value
        let navigationResult = await navigation.value
        XCTAssertFalse(prefetchResult.loaded)
        XCTAssertTrue(navigationResult.loaded)
        XCTAssertEqual(transport.count, 1)
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-10-11")
    }

    func testRefreshRetainsSnapshotsAndRejectsOldEpochCompletions() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let fixture = StudyTimePeriodFixture()
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        let old = Task { await controller.prefetchAnalytics(anchorDate: fixture.date("2025-01-01")) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        let refresh = try XCTUnwrap(controller.prepareRefresh(anchorDate: fixture.now))
        XCTAssertNotNil(controller.cachedAnalytics(anchorDate: fixture.date("2026-10-01"), range: .month))
        let fresh = Task { await controller.finishRefresh(refresh) }
        await fulfillment(of: [transport.expecting(3)], timeout: 2)
        try transport.complete(2, fixture: .init(now: "2026-10-18T17:00:00Z"))
        let freshResult = await fresh.value
        try transport.complete(1)
        let oldResult = await old.value
        XCTAssertTrue(freshResult.loaded)
        XCTAssertFalse(oldResult.loaded)
        XCTAssertNil(controller.cachedAnalytics(anchorDate: fixture.date("2025-01-01")))
        XCTAssertEqual(controller.analytics?.generatedAt, StudyTimePeriodFixture(now: "2026-10-18T17:00:00Z").now)
    }

    func testFailedRefreshKeepsTheVisibleAndAdjacentSnapshots() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let fixture = StudyTimePeriodFixture()
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        let visible = controller.analytics
        let refresh = Task { await controller.refreshAnalytics() }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        try transport.complete(1, error: URLError(.notConnectedToInternet))
        let result = await refresh.value
        XCTAssertFalse(result.loaded)
        XCTAssertEqual(controller.analytics, visible)
        XCTAssertNotNil(controller.cachedAnalytics(anchorDate: fixture.date("2026-10-11"), range: .week))
    }

    func testAccountChangePreventsOldSharedRequestFromPublishingOrWarmingNewCache() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let anchor = StudyTimePeriodFixture().now
        let old = Task { await controller.loadAnalytics(anchorDate: anchor) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        controller.deactivate()
        controller.activate(userID: 43)
        let fresh = Task { await controller.loadAnalytics(anchorDate: anchor) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        try transport.complete(1, fixture: .init(now: "2026-10-18T17:00:00Z"))
        _ = await fresh.value
        try transport.complete(0)
        let result = await old.value
        XCTAssertFalse(result.loaded)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(controller.analytics?.generatedAt, StudyTimePeriodFixture(now: "2026-10-18T17:00:00Z").now)
    }

    func testTimezoneChangeCancelsOldWorkAndUsesSeparateCalendarCoverage() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        var timezone = TimeZone(identifier: "America/New_York")!
        let controller = transport.makeController(timeZone: { timezone })
        let anchor = StudyTimePeriodFixture().date("2026-10-18")
        let old = Task { await controller.loadAnalytics(anchorDate: anchor) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        timezone = TimeZone(identifier: "Asia/Tokyo")!
        let fresh = Task { await controller.loadAnalytics(anchorDate: anchor, range: .month) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        try transport.complete(1, fixture: .init(timezone: "Asia/Tokyo"))
        let freshResult = await fresh.value
        try transport.complete(0)
        let oldResult = await old.value
        XCTAssertTrue(freshResult.loaded)
        XCTAssertFalse(oldResult.loaded)
        XCTAssertEqual(controller.analytics?.timezone, "Asia/Tokyo")
        XCTAssertEqual(controller.cachedAnalytics(anchorDate: anchor, range: .month)?.timezone, "Asia/Tokyo")
    }

    func testStaleSelectionsDisplayImmediatelyAndOldRevalidationCannotTakeOver() async throws {
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController()
        let fixture = StudyTimePeriodFixture()
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        _ = controller.prepareRefresh(anchorDate: fixture.now)
        XCTAssertTrue(controller.selectCachedAnalytics(anchorDate: fixture.date("2026-10-01"), range: .month))
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-10-01")
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        XCTAssertTrue(controller.selectCachedAnalytics(anchorDate: fixture.date("2026-10-11"), range: .week))
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-10-11")
        await fulfillment(of: [transport.expecting(3)], timeout: 2)
        try transport.complete(1)
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-10-11")
        try transport.complete(2)
        // Join the revalidation transport instead of using a timing-dependent sleep.
        let result = await controller.prefetchAnalytics(anchorDate: fixture.date("2026-10-11"), range: .week)
        XCTAssertTrue(result.loaded)
        XCTAssertEqual(transport.count, 3)
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-10-11")
    }
}

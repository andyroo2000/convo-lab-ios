import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePersistentCacheTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var cache: UserDefaultsStudyTimeSnapshotCache!

    override func setUp() async throws {
        try await super.setUp()
        suite = "persistent-period-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testActualDiskRoundTripRestoresHistoricalCoverageButRevalidatesIt() async throws {
        let warm = StudyTimePeriodHarness(snapshotCache: cache)
        for anchor in ["2026-10-18", "2026-09-01", "2026-08-01"] {
            _ = await warm.controller.loadAnalytics(anchorDate: warm.fixture.date(anchor))
        }
        warm.controller.deactivate()
        let restored = StudyTimePeriodHarness(snapshotCache: cache)
        XCTAssertNotNil(restored.controller.analytics?.range(.week))
        XCTAssertEqual(restored.requests.current, 0)
        let target = restored.fixture.date("2026-09-01")
        XCTAssertTrue(restored.controller.selectCachedAnalytics(anchorDate: target, range: .month))
        XCTAssertEqual(restored.controller.analytics?.anchorDate, "2026-09-01")
        XCTAssertEqual(restored.requests.current, 0)
        let fresh = await restored.controller.prefetchAnalytics(anchorDate: target, range: .month)
        XCTAssertTrue(fresh.loaded)
        XCTAssertEqual(restored.requests.current, 1)
        XCTAssertNotNil(restored.controller.cachedAnalytics(anchorDate: target, range: .today)?.range(.today))
    }

    func testFailedRestoredRevalidationKeepsTheReadableChart() async throws {
        let warm = StudyTimePeriodHarness(snapshotCache: cache)
        let target = warm.fixture.date("2026-09-01")
        _ = await warm.controller.loadAnalytics(anchorDate: target)
        warm.controller.deactivate()
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController(now: { warm.fixture.now }, snapshotCache: cache)
        XCTAssertTrue(controller.selectCachedAnalytics(anchorDate: target, range: .month))
        let visible = controller.analytics
        let joined = expectation(description: "Joined restored revalidation")
        let waiting = Task {
            joined.fulfill()
            return await controller.prefetchAnalytics(anchorDate: target, range: .month)
        }
        await fulfillment(of: [transport.expecting(1), joined], timeout: 2)
        try transport.complete(0, error: URLError(.notConnectedToInternet))
        let result = await waiting.value
        XCTAssertFalse(result.loaded)
        XCTAssertEqual(controller.analytics, visible)
        XCTAssertEqual(transport.count, 1)
    }

    func testPersistedHistoryIsBoundedAndIsolatedByAccountAndTimezone() async throws {
        let harness = StudyTimePeriodHarness(snapshotCache: cache)
        for month in 1...14 {
            let anchor = harness.fixture.calendar.date(byAdding: .month, value: -month, to: harness.fixture.now)!
            _ = await harness.controller.loadAnalytics(anchorDate: anchor)
        }
        let saved = try XCTUnwrap(cache.load(userID: 42, timeZone: "America/New_York"))
        XCTAssertEqual(saved.periodHistory?.snapshots.count, 12)
        let restored = StudyTimePeriodHarness(snapshotCache: cache)
        XCTAssertNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.date("2026-09-18"), range: .month))
        XCTAssertNotNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.date("2025-08-18"), range: .month))
        restored.controller.activate(userID: 43)
        XCTAssertNil(restored.controller.analytics)
        XCTAssertNil(restored.controller.cachedAnalytics(anchorDate: restored.fixture.date("2025-08-18"), range: .month))
        let tokyo = StudyTimePeriodHarness(fixture: .init(timezone: "Asia/Tokyo"), snapshotCache: cache)
        XCTAssertNil(tokyo.controller.analytics)
    }

    func testLateAnalyticsCannotRecreateDeletedSnapshot() async throws {
        let fixture = StudyTimePeriodFixture()
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController(now: { fixture.now }, snapshotCache: cache)
        let request = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        controller.deleteLocalData(userID: 42)
        try transport.complete(0)
        let result = await request.value
        XCTAssertFalse(result.loaded)
        XCTAssertNil(cache.load(userID: 42, timeZone: "America/New_York"))
        XCTAssertNil(controller.analytics)
    }

    func testLateAnalyticsAfterDeactivationCannotReplaceTheSavedSnapshot() async throws {
        let fixture = StudyTimePeriodFixture()
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController(now: { fixture.now }, snapshotCache: cache)
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.now) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        let saved = cache.load(userID: 42, timeZone: "America/New_York")
        let pending = Task { await controller.prefetchAnalytics(anchorDate: fixture.date("2026-09-01"), range: .month) }
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        controller.deactivate()
        try transport.complete(1)
        let result = await pending.value
        XCTAssertFalse(result.loaded)
        XCTAssertEqual(cache.load(userID: 42, timeZone: "America/New_York"), saved)
    }

    func testLateRecapCannotRecreateDeletedSnapshot() async throws {
        let fixture = StudyTimePeriodFixture()
        let started = expectation(description: "Recap started")
        let recap = PersistentCacheDeferredRecap(started: started)
        let api = APIClient(baseURL: URL(string: "https://unused.test")!)
        let controller = StudyTimeInsightsController(api: api, weeklyRecapService: recap,
                                                    snapshotCache: cache, now: { fixture.now },
                                                    timeZone: { fixture.calendar.timeZone })
        controller.activate(userID: 42)
        let request = Task { await controller.loadWeeklyRecap(timeZone: "America/New_York") }
        await fulfillment(of: [started], timeout: 2)
        controller.deleteLocalData(userID: 42)
        recap.complete(now: fixture.now)
        await request.value
        XCTAssertNil(cache.load(userID: 42, timeZone: "America/New_York"))
        XCTAssertNil(controller.weeklyRecap)
        XCTAssertFalse(controller.weeklyRecapIsLoading)
    }
}

@MainActor
private final class PersistentCacheDeferredRecap: WeeklyStudyRecapServing {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<WeeklyStudyRecap, Never>?

    init(started: XCTestExpectation) { self.started = started }
    nonisolated deinit {}

    func recap(timeZone: String, weekStartsOn: Int) async throws -> WeeklyStudyRecap {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(now: Date) {
        continuation?.resume(returning: .init(
            generatedAt: now,
            week: .init(startsAt: now.addingTimeInterval(-604_800), endsAt: now, totalMs: 0,
                        activeDays: 0, reviewCount: 0, recallRate: nil, newCardsIntroduced: 0, bestDay: nil,
                        categories: .init(review: 0, listen: 0, create: 0, immerse: 0, conversation: 0, wanikani: 0)),
            previousWeek: .init(totalMs: 0, activeDays: 0, reviewCount: 0, recallRate: nil, newCardsIntroduced: 0)
        ))
        continuation = nil
    }
}

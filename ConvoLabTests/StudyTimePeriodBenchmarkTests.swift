import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePeriodBenchmarkTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testRepeatedPeriodNavigationWithControlledLatency() async throws {
        try await measureNavigation(usingPrefetch: false)
    }

    func testRepeatedSwipeNavigationWithControlledLatency() async throws {
        try await measureNavigation(usingPrefetch: true)
    }

    private func measureNavigation(usingPrefetch: Bool) async throws {
        let harness = StudyTimePeriodHarness(delay: .milliseconds(200))
        let initial = await harness.controller.loadAnalytics(anchorDate: harness.fixture.date("2026-10-18"))
        XCTAssertTrue(initial.loaded)
        let before = harness.requests.current
        let started = ContinuousClock.now
        let visits: [(String, StudyTimeRange)] = [
            ("2026-09-01", .month), ("2026-10-01", .month),
            ("2025-01-01", .year), ("2026-01-01", .year),
            ("2026-10-11", .week), ("2026-10-18", .week),
        ]
        for (anchor, range) in visits {
            let loaded = await navigate(harness, anchor: anchor, range: range, usingPrefetch: usingPrefetch)
            XCTAssertTrue(loaded)
        }
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(harness.requests.current - before, 2)
        let metrics: [String: Any] = [
            "scenario": usingPrefetch ? "swipe-prefetch-selection" : "explicit-period-load",
            "transportLatencyMs": 200,
            "visits": visits.count,
            "requests": harness.requests.current - before,
            "elapsedMs": Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15,
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("TIME_PERIOD_CACHE_JSON \(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-period-cache.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func navigate(
        _ harness: StudyTimePeriodHarness, anchor: String,
        range: StudyTimeRange, usingPrefetch: Bool
    ) async -> Bool {
        let date = harness.fixture.date(anchor)
        if harness.controller.selectCachedAnalytics(anchorDate: date, range: range) { return true }
        if usingPrefetch {
            let loaded = await harness.controller.prefetchAnalytics(anchorDate: date, range: range)
            return loaded.loaded && harness.controller.selectCachedAnalytics(anchorDate: date, range: range)
        }
        return await harness.controller.loadAnalytics(anchorDate: date, range: range).loaded
    }
}

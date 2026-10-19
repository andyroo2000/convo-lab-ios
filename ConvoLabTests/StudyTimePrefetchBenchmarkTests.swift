import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePrefetchBenchmarkTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testPreparedMonthTraversalWithControlledLatency() async throws {
        let harness = StudyTimePeriodHarness(delay: .milliseconds(200))
        let initial = await harness.controller.loadAnalytics(anchorDate: harness.fixture.now, range: .month)
        XCTAssertTrue(initial.loaded)
        let initialRequests = harness.requests.current
        // The fixed preparation window is outside the traversal timer.
        harness.controller.updatePrefetching(range: .month)
        try await Task.sleep(for: .milliseconds(650))
        let preparationRequests = harness.requests.current - initialRequests
        let prepared = ["2026-09-01", "2026-08-01"].filter {
            harness.controller.cachedAnalytics(anchorDate: harness.fixture.date($0), range: .month) != nil
        }.count
        let started = ContinuousClock.now
        for anchor in ["2026-09-01", "2026-08-01", "2026-09-01", "2026-10-01"] {
            let result = await harness.controller.loadAnalytics(anchorDate: harness.fixture.date(anchor), range: .month)
            XCTAssertTrue(result.loaded)
            XCTAssertNotNil(harness.controller.analytics?.range(.month))
        }
        let elapsed = started.duration(to: .now)
        let total = harness.requests.current - initialRequests
        let metrics: [String: Any] = [
            "scenario": "prepared-month-traversal", "transportLatencyMs": 200,
            "preparationWindowMs": 650, "preparedOlderMonths": prepared,
            "preparationRequests": preparationRequests, "totalRequests": total,
            "requestsDuringTraversal": total - preparationRequests,
            "visits": 4,
            "traversalMs": Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15,
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("TIME_PREFETCH_JSON \(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-prefetch.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        harness.controller.deactivate()
    }
}

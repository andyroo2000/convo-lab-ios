import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeAnalyticsPrefetchTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testViewportPrioritizesTwoPeriodsInTravelDirectionAndExcludesFuture() {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        var viewport = StudyTimeAnalyticsViewport()
        func anchors(_ targets: [StudyTimeAnalyticsPrefetch.Target]) -> [String] { targets.map { fixture.anchor($0.anchor) } }
        XCTAssertEqual(anchors(viewport.targets(anchor: fixture.now, range: .month,
                                                generatedAt: fixture.now, context: context)), ["2026-09-01", "2026-08-01"])
        XCTAssertEqual(anchors(viewport.targets(anchor: fixture.date("2026-08-01"), range: .month,
                                                generatedAt: fixture.now, context: context)), ["2026-07-01", "2026-06-01", "2026-09-01"])
        XCTAssertEqual(anchors(viewport.targets(anchor: fixture.date("2026-09-01"), range: .month,
                                                generatedAt: fixture.now, context: context)), ["2026-10-01", "2026-08-01"])
        XCTAssertTrue(viewport.targets(anchor: fixture.now, range: .all, generatedAt: fixture.now, context: context).isEmpty)
    }

    func testPlannerRetainsUsefulWorkBoundsQueueAndPrioritizesForeground() async {
        let planner = StudyTimeAnalyticsPrefetch()
        let probe = PrefetchContinuationProbe()
        let targets = (1...4).map { StudyTimeAnalyticsPrefetch.Target(anchor: Date(timeIntervalSince1970: Double($0)), range: .month) }
        planner.update(targets) { await probe.run($0) }
        await fulfillment(of: [probe.expecting(1)], timeout: 2)
        planner.update([targets[0], targets[2], targets[1]]) { await probe.run($0) }
        planner.beginForeground()
        probe.finish(targets[0])
        let drained = expectation(description: "Completed speculative consumer")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(probe.started, [targets[0]])
        planner.endForeground()
        await fulfillment(of: [probe.expecting(2)], timeout: 2)
        XCTAssertEqual(probe.started[1], targets[2])
        probe.finish(targets[2])
        await fulfillment(of: [probe.expecting(3)], timeout: 2)
        XCTAssertEqual(probe.started[2], targets[1])
        planner.cancel()
        probe.finish(targets[1])
        XCTAssertFalse(probe.started.contains(targets[3]))
    }

    func testCancelledPlannerCompletionCannotStartAnObsoleteQueue() async {
        let planner = StudyTimeAnalyticsPrefetch()
        let probe = PrefetchContinuationProbe()
        let targets = (1...3).map { StudyTimeAnalyticsPrefetch.Target(anchor: Date(timeIntervalSince1970: Double($0)), range: .week) }
        planner.update([targets[0], targets[1]]) { await probe.run($0) }
        await fulfillment(of: [probe.expecting(1)], timeout: 2)
        planner.update([targets[2]]) { await probe.run($0) }
        await fulfillment(of: [probe.expecting(2)], timeout: 2)
        probe.finish(targets[0])
        probe.finish(targets[2])
        planner.cancel()
        XCTAssertEqual(probe.started, [targets[0], targets[2]])
    }

    func testControllerKeepsUsefulMonthPrefetchAcrossNavigationAndWarmsSecondOlderMonth() async throws {
        let fixture = StudyTimePeriodFixture()
        let transport = StudyTimeControlledAnalyticsTransport()
        let controller = transport.makeController(now: { fixture.now })
        let initial = Task { await controller.loadAnalytics(anchorDate: fixture.now, range: .month) }
        await fulfillment(of: [transport.expecting(1)], timeout: 2)
        try transport.complete(0)
        _ = await initial.value
        controller.updatePrefetching(range: .month)
        await fulfillment(of: [transport.expecting(2)], timeout: 2)
        let joined = expectation(description: "Foreground joined September")
        let navigation = Task {
            joined.fulfill()
            return await controller.loadAnalytics(anchorDate: fixture.date("2026-09-01"), range: .month)
        }
        await fulfillment(of: [joined], timeout: 2)
        try transport.complete(1)
        let result = await navigation.value
        XCTAssertTrue(result.loaded)
        controller.updatePrefetching(range: .month)
        await fulfillment(of: [transport.expecting(3)], timeout: 2)
        XCTAssertEqual(anchor(in: transport.urls[2]), "2026-08-01")
        try transport.complete(2)
        await fulfillment(of: [transport.expecting(4)], timeout: 2)
        XCTAssertEqual(anchor(in: transport.urls[3]), "2026-07-01")
        XCTAssertNotNil(controller.cachedAnalytics(anchorDate: fixture.date("2026-08-01"), range: .month))
        XCTAssertEqual(controller.analytics?.anchorDate, "2026-09-01")
        controller.stopPrefetching()
        try transport.complete(3)
        controller.deactivate()
    }

    private func anchor(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "anchorDate" }?.value
    }
}

@MainActor
private final class PrefetchContinuationProbe {
    private(set) var started: [StudyTimeAnalyticsPrefetch.Target] = []
    private var continuations: [Date: CheckedContinuation<Void, Never>] = [:]
    private var expectations: [Int: XCTestExpectation] = [:]
    nonisolated deinit {}

    func run(_ target: StudyTimeAnalyticsPrefetch.Target) async {
        await withCheckedContinuation { continuation in
            continuations[target.anchor] = continuation
            started.append(target)
            expectations.removeValue(forKey: started.count)?.fulfill()
        }
    }

    func expecting(_ count: Int) -> XCTestExpectation {
        let result = XCTestExpectation(description: "Speculative consumer \(count)")
        if started.count >= count { result.fulfill() } else { expectations[count] = result }
        return result
    }

    func finish(_ target: StudyTimeAnalyticsPrefetch.Target) { continuations.removeValue(forKey: target.anchor)?.resume() }
}

import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePersistentCacheBenchmarkTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testRelaunchHistoricalChartReadinessWithControlledLatency() async throws {
        let suite = "period-relaunch-benchmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
        let warm = StudyTimePeriodHarness(delay: .milliseconds(200), snapshotCache: cache)
        for anchor in ["2026-10-18", "2026-09-01", "2026-08-01"] {
            let result = await warm.controller.loadAnalytics(anchorDate: warm.fixture.date(anchor), range: .month)
            XCTAssertTrue(result.loaded)
        }
        warm.controller.deactivate()
        let started = ContinuousClock.now
        let restored = StudyTimePeriodHarness(delay: .milliseconds(200), snapshotCache: cache)
        let target = restored.fixture.date("2026-09-01")
        let result = await restored.controller.loadAnalytics(anchorDate: target, range: .month)
        let elapsed = started.duration(to: .now)
        XCTAssertTrue(result.loaded)
        XCTAssertEqual(restored.controller.analytics?.anchorDate, "2026-09-01")
        let requestsAtReadiness = restored.requests.current
        let refreshed = await restored.controller.prefetchAnalytics(anchorDate: target, range: .month)
        XCTAssertTrue(refreshed.loaded)
        let metrics: [String: Any] = [
            "scenario": "historical-chart-after-relaunch", "transportLatencyMs": 200,
            "requestsAtReadiness": requestsAtReadiness,
            "requestsAfterRevalidation": restored.requests.current,
            "firstChartMs": Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15,
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("TIME_PERSISTENT_CACHE_JSON \(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-persistent-cache.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBoundedSnapshotEncodingAndWriteSubmissionOnMainActor() async throws {
        let suite = "period-write-benchmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        let history = StudyTimePeriodHistory(userID: 42, context: context, snapshots: expandedSnapshots(fixture))
        var milliseconds: [Double] = []
        var encodedBytes = 0
        for iteration in 0..<30 {
            let snapshot = StudyTimeSnapshot(savedAt: fixture.now.addingTimeInterval(Double(iteration)),
                                             analytics: history.snapshots.last?.value, weeklyRecap: nil,
                                             periodHistory: history)
            let started = ContinuousClock.now
            cache.save(snapshot, userID: 42, timeZone: context.timeZone.identifier)
            let elapsed = started.duration(to: .now)
            milliseconds.append(Double(elapsed.components.seconds) * 1_000
                                + Double(elapsed.components.attoseconds) / 1e15)
            encodedBytes = (defaults.persistentDomain(forName: suite) ?? [:]).values
                .compactMap { $0 as? Data }.reduce(0) { $0 + $1.count }
        }
        XCTAssertEqual(cache.load(userID: 42, timeZone: context.timeZone.identifier)?.periodHistory?.snapshots.count, 12)
        let sorted = milliseconds.sorted()
        let metrics: [String: Any] = [
            "scenario": "bounded-snapshot-main-actor-write", "responses": 12,
            "categories": 6, "iterations": milliseconds.count, "encodedBytes": encodedBytes,
            "meanMs": milliseconds.reduce(0, +) / Double(milliseconds.count),
            "p95Ms": sorted[28], "maxMs": sorted.last!,
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("TIME_PERSISTENT_CACHE_JSON \(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-period-write.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func expandedSnapshots(_ fixture: StudyTimePeriodFixture) -> [StudyTimePeriodSnapshot] {
        (0..<12).map { offset in
            let anchor = fixture.calendar.date(byAdding: .month, value: -offset, to: fixture.now)!
            let response = fixture.response(anchor: anchor)
            let ranges = response.ranges.map { range in
                let buckets = range.buckets.map { bucket in
                    let categories = Dictionary(uniqueKeysWithValues: StudyActivityCategory.allCases.enumerated().map {
                        ($0.element.rawValue, bucket.totalMs > 0 ? ($0.offset + 1) * 60_001 : 0)
                    })
                    return StudyTimeAnalyticsBucket(startsAt: bucket.startsAt, endsAt: bucket.endsAt,
                                                    totalMs: categories.values.reduce(0, +), categories: categories)
                }
                let categories = buckets.reduce(into: [String: Int]()) { result, bucket in
                    for (category, duration) in bucket.categories { result[category, default: 0] += duration }
                }
                return StudyTimeAnalyticsRange(key: range.key, startsAt: range.startsAt, endsAt: range.endsAt,
                                               totalMs: categories.values.reduce(0, +), categories: categories, buckets: buckets)
            }
            return .init(value: .init(generatedAt: response.generatedAt, anchorDate: response.anchorDate,
                                      timezone: response.timezone, ranges: ranges), receivedAt: fixture.now)
        }
    }
}

import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeSnapshotStorageTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var cache: UserDefaultsStudyTimeSnapshotCache!
    private let timezone = "America/New_York"

    override func setUp() async throws {
        try await super.setUp()
        suite = "snapshot-storage-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testFractionalDatesRoundTripWithoutChangingTheFreshnessBoundary() async throws {
        let snapshot = makeSnapshot(fraction: 0.875)
        cache.save(snapshot, userID: 42, timeZone: timezone)
        let restored = try XCTUnwrap(cache.load(userID: 42, timeZone: timezone))
        XCTAssertEqual(restored, snapshot)
        let period = try XCTUnwrap(restored.periodHistory?.snapshots.first)
        let entry = StudyTimePeriodCache.Entry(value: period.value, generation: 1, receivedAt: period.receivedAt)
        let context = StudyTimeAnalyticsCalendar(timeZone: TimeZone(identifier: timezone)!)
        XCTAssertTrue(StudyTimePeriodFreshness.isFresh(
            entry, generation: 1, now: snapshot.savedAt.addingTimeInterval(119.5), context: context
        ))
        XCTAssertFalse(StudyTimePeriodFreshness.isFresh(
            entry, generation: 1, now: snapshot.savedAt.addingTimeInterval(120), context: context
        ))
    }

    func testExistingISO8601SnapshotsRemainReadable() async throws {
        let snapshot = makeSnapshot()
        cache.save(snapshot, userID: 42, timeZone: timezone)
        let storedKey = try XCTUnwrap(defaults.persistentDomain(forName: suite)?.keys.first)
        let legacy = JSONEncoder()
        legacy.dateEncodingStrategy = .iso8601
        defaults.set(try legacy.encode(snapshot), forKey: storedKey)
        XCTAssertEqual(cache.load(userID: 42, timeZone: timezone), snapshot)
    }

    func testOversizedResponseRemovesOnlyTheAffectedStoredSnapshot() async throws {
        let snapshot = makeSnapshot()
        cache.save(snapshot, userID: 42, timeZone: timezone)
        cache.save(snapshot, userID: 43, timeZone: timezone)
        let oversized = makeSnapshot(anchor: String(repeating: "x", count: 600_000))
        cache.save(oversized, userID: 42, timeZone: timezone)
        XCTAssertNil(cache.load(userID: 42, timeZone: timezone))
        XCTAssertEqual(cache.load(userID: 43, timeZone: timezone), snapshot)
    }

    func testOversizedExistingBlobIsDiscardedBeforeDecoding() async throws {
        cache.save(makeSnapshot(), userID: 42, timeZone: timezone)
        let storedKey = try XCTUnwrap(defaults.persistentDomain(forName: suite)?.keys.first)
        defaults.set(Data(repeating: 0, count: 600_000), forKey: storedKey)
        XCTAssertNil(cache.load(userID: 42, timeZone: timezone))
        XCTAssertNil(defaults.data(forKey: storedKey))
    }

    private func makeSnapshot(fraction: TimeInterval = 0, anchor: String = "2026-10-18") -> StudyTimeSnapshot {
        let fixture = StudyTimePeriodFixture()
        let now = fixture.now.addingTimeInterval(fraction)
        let range = StudyTimeAnalyticsRange(
            key: .today, startsAt: fixture.calendar.startOfDay(for: now),
            endsAt: fixture.calendar.date(byAdding: .day, value: 1, to: fixture.calendar.startOfDay(for: now))!,
            totalMs: 0, categories: [:], buckets: []
        )
        let analytics = StudyTimeAnalytics(generatedAt: now, anchorDate: anchor, timezone: timezone, ranges: [range])
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        let history = StudyTimePeriodHistory(userID: 42, context: context,
                                            snapshots: [.init(value: analytics, receivedAt: now)])
        return .init(savedAt: now, analytics: analytics, weeklyRecap: nil,
                     weeklyRecapRefreshedAt: now, periodHistory: history)
    }
}

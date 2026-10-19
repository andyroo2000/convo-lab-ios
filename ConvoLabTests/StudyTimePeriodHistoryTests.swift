import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimePeriodHistoryTests: XCTestCase {
    func testResponseAgesAreNotExtendedByNewerEnvelopeWrites() {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        let value = fixture.response(anchor: fixture.now)
        let history = StudyTimePeriodHistory(userID: 42, context: context, snapshots: [
            .init(value: value, receivedAt: fixture.now.addingTimeInterval(-8 * 86_400)),
            .init(value: value, receivedAt: fixture.now.addingTimeInterval(60)),
            .init(value: value, receivedAt: fixture.now.addingTimeInterval(-60)),
        ])
        let restored = history.restored(userID: 42, context: context, now: fixture.now)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.receivedAt, fixture.now.addingTimeInterval(-60))
        XCTAssertTrue(history.restored(userID: 43, context: context, now: fixture.now).isEmpty)
        XCTAssertTrue(history.restored(userID: 42, context: .init(timeZone: context.timeZone, weekStartsOn: 1),
                                       now: fixture.now).isEmpty)
        XCTAssertTrue(history.restored(userID: 42, context: .init(timeZone: TimeZone(identifier: "Asia/Tokyo")!),
                                       now: fixture.now).isEmpty)
    }

    func testUnknownHistoryVersionIsIgnoredAndPartialCoverageIsPreserved() throws {
        let fixture = StudyTimePeriodFixture()
        let context = StudyTimeAnalyticsCalendar(timeZone: fixture.calendar.timeZone)
        let full = fixture.response(anchor: fixture.now)
        let partial = StudyTimeAnalytics(generatedAt: full.generatedAt, anchorDate: full.anchorDate,
                                         timezone: full.timezone, ranges: [try XCTUnwrap(full.range(.month))])
        let history = StudyTimePeriodHistory(userID: 42, context: context,
                                             snapshots: [.init(value: partial, receivedAt: fixture.now)])
        let restored = history.restored(userID: 42, context: context, now: fixture.now)
        XCTAssertEqual(restored.first?.value.ranges.count, 1)
        XCTAssertNil(restored.first?.value.range(.today))
        let data = try JSONEncoder().encode(history)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 999
        let unknown = try JSONDecoder().decode(StudyTimePeriodHistory.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(unknown.restored(userID: 42, context: context, now: fixture.now).isEmpty)
    }
}

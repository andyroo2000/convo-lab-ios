import Foundation
import XCTest
@testable import ConvoLab

final class JournalProgressTests: XCTestCase {
    func testMissingAndSkewedTimestampsUseTimeOnScreen() {
        let opened = Date(timeIntervalSince1970: 1_000)
        for timestamp in ["", "invalid", "2026-11-12T12:00:00Z", "1970-01-01T00:00:00Z"] {
            XCTAssertEqual(JournalProgressTiming.elapsed(serverTime: timestamp, openedAt: opened, now: opened.addingTimeInterval(12)), 12)
        }
    }

    func testValidServerTimestampIncludesElapsedTimeBeforeOpening() {
        let opened = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(JournalProgressTiming.elapsed(serverTime: "1970-01-01T00:16:30.000Z", openedAt: opened, now: opened.addingTimeInterval(5)), 15)
        XCTAssertEqual(JournalProgressTiming.elapsed(serverTime: "1970-01-01T00:16:30Z", openedAt: opened, now: opened.addingTimeInterval(5)), 15)
    }

    func testEstimatedBarWaitsForActualCompletion() {
        XCTAssertEqual(JournalProgressTiming.fraction(elapsed: 60, status: .queued), 0.08)
        XCTAssertGreaterThan(JournalProgressTiming.fraction(elapsed: 60, status: .processing), JournalProgressTiming.fraction(elapsed: 5, status: .processing))
        XCTAssertLessThanOrEqual(JournalProgressTiming.fraction(elapsed: 600, status: .processing), 0.94)
    }

    func testLegacyPraiseDecodesButDoesNotHighlightOrOfferAnExplanation() throws {
        let kind = try JSONDecoder().decode(JournalSegment.Kind.self, from: Data("\"keep\"".utf8))
        XCTAssertFalse(kind.isHighlighted)
        XCTAssertFalse(JournalSegment.Kind.plain.isHighlighted)
        XCTAssertTrue(JournalSegment.Kind.correction.isHighlighted)
        XCTAssertTrue(JournalSegment.Kind.optional.isHighlighted)
    }
}

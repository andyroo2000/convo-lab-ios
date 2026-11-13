import XCTest
@testable import ConvoLab

@MainActor
final class JournalWritingRecapTests: XCTestCase {
    func testRecapIncludesWritingAndDecodesOlderPayloads() throws {
        let old = #"{"review":10,"listen":20,"create":30,"immerse":40,"conversation":50,"wanikani":60}"#
        let legacy = try JSONDecoder().decode(WeeklyStudyRecapCategories.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.duration(for: .writing), 0)
        XCTAssertEqual(legacy.total, 210)
        let updated = old.dropLast() + #", "writing":90}"#
        let current = try JSONDecoder().decode(WeeklyStudyRecapCategories.self, from: Data(updated.utf8))
        XCTAssertEqual(current.duration(for: .writing), 90)
        XCTAssertEqual(current.total, 300)
        XCTAssertEqual(current.duration(for: .review), 10)
    }
}

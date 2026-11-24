import XCTest
@testable import ConvoLab

@MainActor
final class StudyCardLayoutTests: XCTestCase {
    func testReadingSizeUsesVisibleBaseText() {
        XCTAssertEqual(StudyReadingSize("  娘[むすめ]  "), .character)
        XCTAssertEqual(StudyReadingSize("日本ABC"), .word)
        XCTAssertEqual(StudyReadingSize(String(repeating: "あ", count: 6)), .sentence)
        XCTAssertEqual(StudyReadingSize(""), .phrase)
        XCTAssertEqual(StudyReadingSize(String(repeating: "A", count: 32)), .phrase)
        XCTAssertEqual(StudyReadingSize(String(repeating: "A", count: 33)), .sentence)
        XCTAssertEqual(StudyReadingSize(String(repeating: "あ", count: 45)), .sentence)
        XCTAssertEqual(StudyReadingSize(String(repeating: "あ", count: 46)), .passage)
    }

    func testReviewProgressAccountsForRequeuedAndUnloadedCards() {
        let reviewed: Set<String> = ["finished", "again"]
        let queued: Set<String> = ["again", "new"]
        XCTAssertEqual(StudyCardProgress.review(reviewed: reviewed, queued: queued, due: 1),
                       StudyCardProgress(completed: 1, total: 3))
        XCTAssertEqual(StudyCardProgress.review(reviewed: reviewed, queued: queued, due: 8),
                       StudyCardProgress(completed: 1, total: 9))
    }

    func testBatchProgressHandlesAnExpandingQueue() {
        XCTAssertEqual(StudyCardProgress.batch(total: 4, remaining: 3), StudyCardProgress(completed: 1, total: 4))
        XCTAssertEqual(StudyCardProgress.batch(total: 4, remaining: 5), StudyCardProgress(completed: 0, total: 5))
    }
}

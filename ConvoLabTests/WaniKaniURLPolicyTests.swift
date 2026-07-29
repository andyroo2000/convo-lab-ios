import XCTest
@testable import ConvoLab

final class WaniKaniURLPolicyTests: XCTestCase {
    func testRecognizesCurrentReviewRoutes() {
        XCTAssertTrue(
            WaniKaniURLPolicy.isReviewPage(
                URL(string: "https://www.wanikani.com/subjects/review")
            )
        )
        XCTAssertTrue(
            WaniKaniURLPolicy.isReviewPage(
                URL(string: "https://www.wanikani.com/subjects/review/quiz")
            )
        )
    }

    func testDoesNotCountDashboardOrLessonsAsReviews() {
        XCTAssertFalse(
            WaniKaniURLPolicy.isReviewPage(URL(string: "https://www.wanikani.com/dashboard"))
        )
        XCTAssertFalse(
            WaniKaniURLPolicy.isReviewPage(
                URL(string: "https://www.wanikani.com/subjects/lesson")
            )
        )
    }

    func testRejectsLookalikeAndInsecureHosts() {
        XCTAssertFalse(
            WaniKaniURLPolicy.isReviewPage(
                URL(string: "https://wanikani.com.example.com/subjects/review")
            )
        )
        XCTAssertFalse(
            WaniKaniURLPolicy.isReviewPage(
                URL(string: "http://www.wanikani.com/subjects/review")
            )
        )
    }

    func testAllowsSecureWaniKaniSubdomains() {
        XCTAssertTrue(
            WaniKaniURLPolicy.isWaniKaniPage(URL(string: "https://account.wanikani.com/login"))
        )
    }
}

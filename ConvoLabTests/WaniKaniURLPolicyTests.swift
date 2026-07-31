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

    func testAllowsThirdPartyAuthenticationFramesInsideWebView() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://m.stripe.network/inner.html"),
                targetIsMainFrame: false,
                isUserActivated: false
            ),
            .allow
        )
    }

    func testKeepsScriptOpenedAuthenticationWindowInsideWebView() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://m.stripe.network/auth"),
                targetIsMainFrame: nil,
                isUserActivated: false
            ),
            .openBackgroundWindow
        )
    }

    func testPresentsUnknownScriptOpenedWindowInsideApp() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://verify.example.com/challenge"),
                targetIsMainFrame: nil,
                isUserActivated: false
            ),
            .openInteractiveWindow
        )
    }

    func testStillOpensTappedExternalLinksInSystemBrowser() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://knowledge.wanikani.com/"),
                targetIsMainFrame: nil,
                isUserActivated: true
            ),
            .openExternally
        )
    }

    func testLoadsTappedWaniKaniPopupLinkInMainWebView() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://www.wanikani.com/dashboard"),
                targetIsMainFrame: nil,
                isUserActivated: true
            ),
            .loadInMainFrame
        )
    }

    func testCancelsNonWebSubframeNavigation() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "custom-auth://callback"),
                targetIsMainFrame: false,
                isUserActivated: false
            ),
            .cancel
        )
    }

    func testOpensExternalMainFrameNavigationInSystemBrowser() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "https://example.com/"),
                targetIsMainFrame: true,
                isUserActivated: false
            ),
            .openExternally
        )
    }
}

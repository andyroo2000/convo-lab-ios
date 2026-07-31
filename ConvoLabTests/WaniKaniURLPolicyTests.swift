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
                for: URL(string: "https://example.com/"),
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

    func testOpensUserActivatedNonWebSubframeNavigationExternally() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "bank-auth://challenge"),
                targetIsMainFrame: false,
                isUserActivated: true
            ),
            .openExternally
        )
    }

    func testTreatsLinksAndFormSubmissionsAsUserActivated() {
        XCTAssertTrue(WaniKaniURLPolicy.isUserActivated(.linkActivated))
        XCTAssertTrue(WaniKaniURLPolicy.isUserActivated(.formSubmitted))
        XCTAssertFalse(WaniKaniURLPolicy.isUserActivated(.other))
    }

    func testKeepsAutomaticAuxiliaryRedirectInWebKitContext() {
        XCTAssertEqual(
            WaniKaniURLPolicy.auxiliaryNavigationDisposition(
                for: URL(string: "https://verify.example.com/complete"),
                targetIsMainFrame: true,
                isUserActivated: false
            ),
            .allow
        )
    }

    func testOpensTappedExternalAuxiliaryLinkExternally() {
        XCTAssertEqual(
            WaniKaniURLPolicy.auxiliaryNavigationDisposition(
                for: URL(string: "https://example.com/help"),
                targetIsMainFrame: true,
                isUserActivated: true
            ),
            .openExternally
        )
    }

    func testCancelsAutomaticCustomSchemeMainFrameNavigation() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "custom-auth://callback"),
                targetIsMainFrame: true,
                isUserActivated: false
            ),
            .cancel
        )
    }

    func testOpensTappedCustomSchemeMainFrameNavigationExternally() {
        XCTAssertEqual(
            WaniKaniURLPolicy.navigationDisposition(
                for: URL(string: "custom-auth://callback"),
                targetIsMainFrame: true,
                isUserActivated: true
            ),
            .openExternally
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

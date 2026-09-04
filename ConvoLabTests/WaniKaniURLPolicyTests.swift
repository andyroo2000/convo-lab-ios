import XCTest
@testable import ConvoLab

final class WaniKaniURLPolicyTests: XCTestCase {
    private struct PageCase {
        let name: String
        let url: String
        let isReviewPage: Bool
    }

    private struct NavigationCase {
        let name: String
        let url: String
        let targetIsMainFrame: Bool?
        let isUserActivated: Bool
        let expected: WaniKaniURLPolicy.NavigationDisposition
    }

    private static let pageCases = [
        PageCase(
            name: "review root",
            url: "https://www.wanikani.com/subjects/review",
            isReviewPage: true
        ),
        PageCase(
            name: "review quiz",
            url: "https://www.wanikani.com/subjects/review/quiz",
            isReviewPage: true
        ),
        PageCase(name: "dashboard", url: "https://www.wanikani.com/dashboard", isReviewPage: false),
        PageCase(
            name: "lesson",
            url: "https://www.wanikani.com/subjects/lesson",
            isReviewPage: false
        ),
        PageCase(
            name: "lookalike host",
            url: "https://wanikani.com.example.com/subjects/review",
            isReviewPage: false
        ),
        PageCase(
            name: "insecure host",
            url: "http://www.wanikani.com/subjects/review",
            isReviewPage: false
        )
    ]

    private static let navigationCases = [
        NavigationCase(
            name: "third-party authentication frame",
            url: "https://m.stripe.network/inner.html",
            targetIsMainFrame: false,
            isUserActivated: false,
            expected: .allow
        ),
        NavigationCase(
            name: "script-opened authentication window",
            url: "https://m.stripe.network/auth",
            targetIsMainFrame: nil,
            isUserActivated: false,
            expected: .openBackgroundWindow
        ),
        NavigationCase(
            name: "unknown script-opened window",
            url: "https://verify.example.com/challenge",
            targetIsMainFrame: nil,
            isUserActivated: false,
            expected: .openInteractiveWindow
        ),
        NavigationCase(
            name: "tapped external link",
            url: "https://example.com/",
            targetIsMainFrame: nil,
            isUserActivated: true,
            expected: .openExternally
        ),
        NavigationCase(
            name: "tapped WaniKani popup link",
            url: "https://www.wanikani.com/dashboard",
            targetIsMainFrame: nil,
            isUserActivated: true,
            expected: .loadInMainFrame
        ),
        NavigationCase(
            name: "automatic custom-scheme subframe",
            url: "custom-auth://callback",
            targetIsMainFrame: false,
            isUserActivated: false,
            expected: .cancel
        ),
        NavigationCase(
            name: "user-activated custom-scheme subframe",
            url: "bank-auth://challenge",
            targetIsMainFrame: false,
            isUserActivated: true,
            expected: .openExternally
        ),
        NavigationCase(
            name: "automatic custom-scheme main frame",
            url: "custom-auth://callback",
            targetIsMainFrame: true,
            isUserActivated: false,
            expected: .cancel
        ),
        NavigationCase(
            name: "tapped custom-scheme main frame",
            url: "custom-auth://callback",
            targetIsMainFrame: true,
            isUserActivated: true,
            expected: .openExternally
        ),
        NavigationCase(
            name: "external main frame",
            url: "https://example.com/",
            targetIsMainFrame: true,
            isUserActivated: false,
            expected: .openExternally
        )
    ]

    private static let auxiliaryNavigationCases = [
        NavigationCase(
            name: "automatic auxiliary redirect",
            url: "https://verify.example.com/complete",
            targetIsMainFrame: true,
            isUserActivated: false,
            expected: .allow
        ),
        NavigationCase(
            name: "tapped external auxiliary link",
            url: "https://example.com/help",
            targetIsMainFrame: true,
            isUserActivated: true,
            expected: .openExternally
        )
    ]

    func testReviewPageClassification() {
        for testCase in Self.pageCases {
            XCTAssertEqual(
                WaniKaniURLPolicy.isReviewPage(URL(string: testCase.url)),
                testCase.isReviewPage,
                testCase.name
            )
        }
    }

    func testAllowsSecureWaniKaniSubdomains() {
        XCTAssertTrue(
            WaniKaniURLPolicy.isWaniKaniPage(URL(string: "https://account.wanikani.com/login"))
        )
    }

    func testNavigationDispositionCases() {
        assertNavigationDispositions(Self.navigationCases) {
            WaniKaniURLPolicy.navigationDisposition(
                for: $0,
                targetIsMainFrame: $1,
                isUserActivated: $2
            )
        }
    }

    func testTreatsLinksAndFormSubmissionsAsUserActivated() {
        XCTAssertTrue(WaniKaniURLPolicy.isUserActivated(.linkActivated))
        XCTAssertTrue(WaniKaniURLPolicy.isUserActivated(.formSubmitted))
        XCTAssertFalse(WaniKaniURLPolicy.isUserActivated(.other))
    }

    func testAuxiliaryNavigationDispositionCases() {
        assertNavigationDispositions(Self.auxiliaryNavigationCases) {
            WaniKaniURLPolicy.auxiliaryNavigationDisposition(
                for: $0,
                targetIsMainFrame: $1,
                isUserActivated: $2
            )
        }
    }

    private func assertNavigationDispositions(
        _ cases: [NavigationCase],
        policy: (URL?, Bool?, Bool) -> WaniKaniURLPolicy.NavigationDisposition
    ) {
        for testCase in cases {
            XCTAssertEqual(
                policy(
                    URL(string: testCase.url),
                    testCase.targetIsMainFrame,
                    testCase.isUserActivated
                ),
                testCase.expected,
                testCase.name
            )
        }
    }
}

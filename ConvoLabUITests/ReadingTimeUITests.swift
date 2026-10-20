import XCTest

final class ReadingTimeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testReadingTimeFollowsReaderNavigationAndSceneLifecycle() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "readings", "-ui-test-reset", "-ui-test-reading-time"]
        app.launch()
        let book = app.buttons["reading-library-collection"]
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        waitForValue("idle", element: app.staticTexts["reading-time-active"])
        waitForCount(0, in: app)

        book.tap()
        XCTAssertTrue(app.buttons["reading-book-back"].waitForExistence(timeout: 5))
        waitForValue("idle", element: app.staticTexts["reading-time-active"])
        waitForCount(0, in: app)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "小さな犬")).firstMatch.tap()
        let firstInterval = waitForReading(in: app)
        waitForCount(0, in: app)

        app.buttons["Page 24, choose page"].tap()
        app.buttons["Page 25"].tap()
        XCTAssertTrue(app.webViews.buttons["犬は家へ帰りました。"].waitForExistence(timeout: 5))
        waitForValue(firstInterval, element: app.staticTexts["reading-time-active"])
        waitForCount(0, in: app)

        app.buttons["reading-back"].tap()
        XCTAssertTrue(app.buttons["reading-book-back"].waitForExistence(timeout: 5))
        waitForValue("idle", element: app.staticTexts["reading-time-active"])
        waitForCount(1, in: app)
        app.buttons["reading-book-back"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.buttons["reading-library-reading"].tap()
        let reopenedInterval = waitForReading(in: app)
        XCTAssertNotEqual(reopenedInterval, firstInterval)
        waitForCount(1, in: app)

        XCUIDevice.shared.press(.home)
        let leftForeground = app.wait(for: .runningBackground, timeout: 5)
            || app.state == .runningBackgroundSuspended
        XCTAssertTrue(leftForeground)
        let foregroundRequestedAt = Date().timeIntervalSince1970
        app.activate()
        let resumedInterval = waitForReading(in: app)
        XCTAssertNotEqual(resumedInterval, reopenedInterval, "Backgrounding must finish the previous interval")
        waitForCount(2, in: app)
        let finishedAt = app.staticTexts["reading-time-finished-at"].value as? String ?? ""
        XCTAssertLessThanOrEqual(Double(finishedAt) ?? .infinity, foregroundRequestedAt)
        app.buttons["reading-back"].tap()
        waitForValue("idle", element: app.staticTexts["reading-time-active"])
        waitForCount(3, in: app)
    }

    @MainActor
    private func waitForReading(in app: XCUIApplication) -> String {
        let element = app.staticTexts["reading-time-active"]
        let predicate = NSPredicate(format: "value BEGINSWITH %@", "reading|automatic|immerse|小さな犬|")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        return element.value as? String ?? ""
    }

    @MainActor
    private func waitForCount(_ count: Int, in app: XCUIApplication) {
        waitForValue(String(count), element: app.staticTexts["reading-time-completed"])
    }

    @MainActor
    private func waitForValue(_ value: String, element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}

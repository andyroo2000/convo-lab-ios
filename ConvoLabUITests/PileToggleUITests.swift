import XCTest

final class PileToggleUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testChapterSwitchRespondsBeforeSaveAndCountsComplete() {
        let app = launchPiles()
        let toggle = app.switches["Include Chapter 1 in new cards"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(toggle.isEnabled)
        app.buttons["Finish save"].tap()
        waitUntilEnabled(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Refreshing counts"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chapter saved while counts are still refreshing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Finish counts"].tap()
    }

    @MainActor
    func testFailedChapterSwitchRollsBackAndCanRetry() {
        let app = launchPiles()
        let toggle = app.switches["Include Chapter 1 in new cards"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Fail save"].tap()
        XCTAssertTrue(app.staticTexts["Save rejected for test"].waitForExistence(timeout: 5))
        waitUntilEnabled(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["Finish counts"].tap()
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Finish save"].tap()
        waitUntilEnabled(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Finish counts"].tap()
    }

    @MainActor
    private func launchPiles() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "study-dashboard", "-ui-test-piles"]
        app.launch()
        return app
    }

    private func waitUntilEnabled(_ toggle: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }

    private func tapSwitch(_ toggle: XCUIElement) {
        // SwiftUI exposes the whole labeled row; tap the actual trailing switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
}

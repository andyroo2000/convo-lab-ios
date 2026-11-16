import XCTest

final class JournalDraftCloseUITests: XCTestCase {
    @MainActor
    func testCloseCanReturnToWritingOrDeleteTheDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        app.buttons["JournalNewEntry"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Keep draft & close"].waitForExistence(timeout: 5))
        app.buttons["Keep writing"].tap()
        XCTAssertTrue(app.textViews["Journal entry"].exists)
        app.buttons["Close"].tap()
        app.buttons["Delete draft"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
    }
}

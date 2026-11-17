import XCTest

final class JournalDeletionUITests: XCTestCase {
    @MainActor
    func testDraftRowMenuRenamesAndRequiresDeletionConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        app.buttons["JournalNewEntry"].tap()
        XCTAssertTrue(app.textViews["Journal entry"].waitForExistence(timeout: 5))
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        for _ in 0..<5 where !app.buttons["My entries"].isHittable { app.swipeDown() }
        app.buttons["My entries"].tap()
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "JournalRowActions-")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        let actionID = actions.identifier
        actions.tap()
        app.buttons["Rename"].tap()
        let title = app.textFields["JournalRenameTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        title.tap()
        title.typeText("Movie night")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Movie night"].exists)
        actions.tap()
        app.buttons["Rename"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Movie night")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Movie night"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        let body = app.textViews["Journal entry"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        body.typeText("Keep the renamed title.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["My entries"].tap()
        XCTAssertTrue(app.staticTexts["Movie night"].waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Keep entry"].waitForExistence(timeout: 5))
        app.buttons["Keep entry"].tap()
        XCTAssertTrue(actions.exists)
        actions.tap()
        app.buttons["Delete"].tap()
        app.buttons["Delete entry"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[actionID].exists)
        XCTAssertTrue(app.textViews["Journal entry"].waitForNonExistence(timeout: 5))
    }
}

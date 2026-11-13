import XCTest

final class JournalDeletionUITests: XCTestCase {
    @MainActor
    func testDraftRowMenuRenamesAndRequiresDeletionConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["StudyJournalLink"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        app.buttons["JournalNewEntry"].tap()
        XCTAssertTrue(app.textFields["Title (optional)"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
    }
}

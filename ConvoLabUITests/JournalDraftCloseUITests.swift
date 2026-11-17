import XCTest

final class JournalDraftCloseUITests: XCTestCase {
    @MainActor
    func testNewDraftUsesGrowingNotebookPaperAndKeepsWritingAfterReopening() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        let body = app.textViews["Journal entry"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Title (optional)"].exists)
        XCTAssertFalse(app.datePickers.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Untitled entry"].exists)
        XCTAssertFalse(app.staticTexts["Draft saved on this device"].exists)
        let emptyHeight = body.frame.height
        capture(app, name: "Empty notebook draft")
        let text = String(repeating: "A line in my journal.\n", count: 8) + "\n\n"
        body.tap()
        body.typeText(text)
        XCTAssertGreaterThan(body.frame.height, emptyHeight)
        XCTAssertEqual(body.value as? String, text)
        capture(app, name: "Growing notebook draft")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        for _ in 0..<5 where !app.buttons["My entries"].isHittable { app.swipeDown() }
        app.buttons["My entries"].tap()
        let draft = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Untitled entry")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        other.tap()
        XCTAssertTrue(app.buttons["Final"].waitForExistence(timeout: 5))
        app.buttons["My entries"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, text)
        capture(app, name: "Reopened notebook draft")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = name
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    func testCloseCanReturnToWritingOrDeleteTheDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertFalse(app.buttons["Keep draft & close"].exists)
        let body = app.textViews["Journal entry"]
        body.tap()
        body.typeText("An unfinished thought.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Keep draft & close"].waitForExistence(timeout: 5))
        app.buttons["Keep writing"].tap()
        XCTAssertTrue(app.textViews["Journal entry"].exists)
        app.buttons["Close"].tap()
        app.buttons["Delete draft"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, "")
        XCTAssertFalse(app.buttons["Continue draft"].exists)
    }
}

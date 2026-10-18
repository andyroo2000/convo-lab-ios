import XCTest

final class ManualStudyTimeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testManualEntryCanBeAddedEditedAndDeletedFromTimeSection() {
        let app = openManualEntrySection()
        XCTAssertFalse(app.buttons["Add time"].exists)
        XCTAssertFalse(app.buttons["Start session"].exists)
        XCTAssertFalse(app.staticTexts["Timer"].exists)
        app.buttons["ManualStudyTimeAddButton"].tap()

        XCTAssertTrue(app.navigationBars["Add Study Time"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Add to my calendar"].exists)
        XCTAssertTrue(app.staticTexts["Started"].exists)
        XCTAssertTrue(app.steppers["30 minutes"].exists)
        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Paper book reading")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Study Time"].waitForNonExistence(timeout: 8))

        let entry = app.staticTexts["Paper book reading"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Edit Study Time"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Add to my calendar"].exists)
        name.tap()
        name.typeText(" chapter two")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Study Time"].waitForNonExistence(timeout: 8))

        let edited = app.staticTexts["Paper book reading chapter two"]
        reveal(edited, in: app)
        edited.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func openManualEntrySection() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "login-restoration"]
        app.launchEnvironment["UI_TEST_RESET"] = "1"
        app.launch()
        let modePicker = app.buttons["app-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        modePicker.tap()
        app.buttons["Time"].tap()
        let section = app.buttons["ManualStudyTimeSection"]
        reveal(section, in: app)
        section.tap()
        reveal(app.buttons["ManualStudyTimeAddButton"], in: app)
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}

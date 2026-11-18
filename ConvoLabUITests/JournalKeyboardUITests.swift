import XCTest

@MainActor
final class JournalKeyboardUITests: XCTestCase {
    func testOnboardingRequiresChoiceAndRemembersDeviceKeyboard() {
        let app = openJournal(onboarding: true)
        let confirm = app.buttons["JournalKeyboardConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(app.staticTexts["Saved on this device."].exists)
        capture(app, "Keyboard onboarding with two miniature screens")
        app.buttons["JournalKeyboard-device"].tap()
        confirm.tap()
        let field = app.textViews["Journal entry"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("My own keyboard.")
        XCTAssertEqual(field.value as? String, "My own keyboard.")
        app.terminate()
        let reopened = openJournal(onboarding: false)
        XCTAssertFalse(reopened.buttons["JournalKeyboardConfirm"].exists)
        XCTAssertTrue(reopened.textViews["Journal entry"].exists)
        openSettings(reopened)
        XCTAssertTrue(reopened.buttons["JournalKeyboard-device"].isSelected)
        capture(reopened, "Remembered keyboard preference")
    }

    func testBuiltInConversionCandidatesAndSwitchingKeepDraftText() {
        let app = openJournal(onboarding: true)
        XCTAssertTrue(app.buttons["JournalKeyboard-builtIn"].waitForExistence(timeout: 8))
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        let field = app.webViews.textViews["Journal entry"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        let convert = app.webViews.buttons["変換"]
        XCTAssertTrue(convert.waitForExistence(timeout: 120))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: convert)
        waitForExpectations(timeout: 120)
        field.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        field.typeText("hashidetabemashita")
        expectation(for: NSPredicate(format: "value == %@", "箸で食べました"), evaluatedWith: field)
        waitForExpectations(timeout: 40)
        capture(app, "Built-in input on Journal paper")
        convert.tap()
        let bridge = app.webViews.switches["橋で"]
        XCTAssertTrue(bridge.waitForExistence(timeout: 30))
        bridge.tap()
        XCTAssertEqual(field.value as? String, "橋で食べました")
        app.webViews.buttons["Shorten section"].tap()
        XCTAssertTrue(app.webViews.staticTexts["More choices ready · ↑ ↓ choose · ← → sections · Enter to commit."].waitForExistence(timeout: 120))
        capture(app, "Journal full candidates after section adjustment")
        app.webViews.buttons["確定"].tap()
        let converted = field.value as? String
        dismissKeyboard(app)
        openSettings(app)
        app.buttons["JournalKeyboard-device"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        XCTAssertEqual(app.textViews["Journal entry"].value as? String, converted)
        openSettings(app)
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, converted)
    }

    func testBuiltInFinalEditingSavesAndReopensTheConvertedText() {
        let app = openJournal(onboarding: true)
        XCTAssertTrue(app.buttons["JournalKeyboard-device"].waitForExistence(timeout: 8))
        app.buttons["JournalKeyboard-device"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        app.buttons["My entries"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        app.buttons["Final"].tap()
        openSettings(app)
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        app.buttons["More journal options"].firstMatch.tap()
        app.buttons["Edit final"].tap()
        let field = app.webViews.textViews["Final text"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        let convert = app.webViews.buttons["変換"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: convert)
        waitForExpectations(timeout: 120)
        field.tap()
        field.typeText("ohayou")
        app.webViews.buttons["確定"].tap()
        let edited = field.value as? String
        XCTAssertTrue(edited?.contains("おはよう") == true)
        dismissKeyboard(app)
        for _ in 0..<8 where !app.buttons["Save changes"].isHittable { app.swipeUp() }
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.buttons["Listen corrected version"].waitForExistence(timeout: 10))
        app.buttons["More journal options"].firstMatch.tap()
        app.buttons["Edit final"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, edited)
        capture(app, "Saved final text with built-in input")
    }

    private func openJournal(onboarding: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", onboarding ? "-journal-keyboard-onboarding" : "-journal-keyboard-keep"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 10))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        for _ in 0..<8 where !app.buttons["More journal options"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["More journal options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["JournalKeyboardMenu"].waitForExistence(timeout: 5))
        capture(app, "Keyboard below Appearance in the Journal menu")
        app.buttons["JournalKeyboardMenu"].tap()
        XCTAssertTrue(app.buttons["JournalKeyboardConfirm"].waitForExistence(timeout: 5))
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.swipeDown()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
